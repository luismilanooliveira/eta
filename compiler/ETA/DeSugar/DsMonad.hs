{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998


@DsMonad@: monadery used in desugaring
-}

{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}  -- instance MonadThings is necessarily an orphan

module ETA.DeSugar.DsMonad (
        DsM, mapM, mapAndUnzipM,
        initDs, initDsTc, fixDs,
        foldlM, foldrM, whenGOptM, unsetGOptM, unsetWOptM,
        Applicative(..),(<$>),

        newLocalName,
        duplicateLocalDs, newSysLocalDs, newSysLocalsDs, newUniqueId,
        newFailLocalDs, newPredVarDs,
        getSrcSpanDs, putSrcSpanDs,
        mkPrintUnqualifiedDs,
        newUnique,
        UniqSupply, newUniqueSupply,
        getGhcModeDs, dsGetFamInstEnvs, dsGetStaticBindsVar,
        dsLookupGlobal, dsLookupGlobalId, dsDPHBuiltin, dsLookupTyCon, dsLookupDataCon,

        PArrBuiltin(..),
        dsLookupDPHRdrEnv, dsLookupDPHRdrEnv_maybe,
        dsInitPArrBuiltin,

        DsMetaEnv, DsMetaVal(..), dsGetMetaEnv, dsLookupMetaEnv, dsExtendMetaEnv,

        -- Warnings
        DsWarning, warnDs, failWithDs, discardWarningsDs,

        -- Data types
        DsMatchContext(..),
        EquationInfo(..), MatchResult(..), DsWrapper, idDsWrapper,
        CanItFail(..), orFail
    ) where

import ETA.TypeCheck.TcRnMonad
import ETA.Types.FamInstEnv
import ETA.Core.CoreSyn
import ETA.HsSyn.HsSyn
import ETA.Iface.TcIface
import ETA.Iface.LoadIface
import ETA.Main.Finder
import ETA.Prelude.PrelNames
import ETA.BasicTypes.RdrName
import ETA.Main.HscTypes
import ETA.Utils.Bag
import ETA.BasicTypes.DataCon
import ETA.Types.TyCon
import ETA.BasicTypes.Id
import ETA.BasicTypes.Module
import ETA.Utils.Outputable
import ETA.BasicTypes.SrcLoc
import ETA.Types.Type
import ETA.BasicTypes.UniqSupply
import ETA.BasicTypes.Name
import ETA.BasicTypes.NameEnv
import ETA.Main.DynFlags
import ETA.Main.ErrUtils
import ETA.Utils.FastString
import ETA.Utils.Maybes
import GHC.Fingerprint

import Data.IORef
import Control.Monad

{-
************************************************************************
*                                                                      *
                Data types for the desugarer
*                                                                      *
************************************************************************
-}

data DsMatchContext
  = DsMatchContext (HsMatchContext Name) SrcSpan
  deriving ()

data EquationInfo
  = EqnInfo { eqn_pats :: [Pat Id],     -- The patterns for an eqn
              eqn_rhs  :: MatchResult } -- What to do after match

instance Outputable EquationInfo where
    ppr (EqnInfo pats _) = ppr pats

type DsWrapper = CoreExpr -> CoreExpr
idDsWrapper :: DsWrapper
idDsWrapper e = e

-- The semantics of (match vs (EqnInfo wrap pats rhs)) is the MatchResult
--      \fail. wrap (case vs of { pats -> rhs fail })
-- where vs are not bound by wrap


-- A MatchResult is an expression with a hole in it
data MatchResult
  = MatchResult
        CanItFail       -- Tells whether the failure expression is used
        (CoreExpr -> DsM CoreExpr)
                        -- Takes a expression to plug in at the
                        -- failure point(s). The expression should
                        -- be duplicatable!

data CanItFail = CanFail | CantFail

orFail :: CanItFail -> CanItFail -> CanItFail
orFail CantFail CantFail = CantFail
orFail _        _        = CanFail

{-
************************************************************************
*                                                                      *
                Monad functions
*                                                                      *
************************************************************************
-}

-- Compatibility functions
fixDs :: (a -> DsM a) -> DsM a
fixDs    = fixM

type DsWarning = (SrcSpan, SDoc)
        -- Not quite the same as a WarnMsg, we have an SDoc here
        -- and we'll do the print_unqual stuff later on to turn it
        -- into a Doc.

initDs :: HscEnv
       -> Module -> GlobalRdrEnv -> TypeEnv -> FamInstEnv
       -> DsM a
       -> IO (Messages, Maybe a)
-- Print errors and warnings, if any arise

initDs hsc_env mod rdr_env type_env fam_inst_env thing_inside
  = do  { msg_var <- newIORef (emptyBag, emptyBag)
        ; static_binds_var <- newIORef []
        ; let dflags                   = hsc_dflags hsc_env
              (ds_gbl_env, ds_lcl_env) = mkDsEnvs dflags mod rdr_env type_env
                                                  fam_inst_env msg_var
                                                  static_binds_var

        ; either_res <- initTcRnIf 'd' hsc_env ds_gbl_env ds_lcl_env $
                          loadDAP $
                            initDPHBuiltins $
                              tryM thing_inside     -- Catch exceptions (= errors during desugaring)

        -- Display any errors and warnings
        -- Note: if -Werror is used, we don't signal an error here.
        ; msgs <- readIORef msg_var

        ; let final_res | errorsFound dflags msgs = Nothing
                        | otherwise = case either_res of
                                        Right res -> Just res
                                        Left exn  -> pprPanic "initDs" (text (show exn))
                -- The (Left exn) case happens when the thing_inside throws
                -- a UserError exception.  Then it should have put an error
                -- message in msg_var, so we just discard the exception

        ; return (msgs, final_res)
        }
  where
    -- Extend the global environment with a 'GlobalRdrEnv' containing the exported entities of
    --   * 'Data.Array.Parallel'      iff '-XParallelArrays' specified (see also 'checkLoadDAP').
    --   * 'Data.Array.Parallel.Prim' iff '-fvectorise' specified.
    loadDAP thing_inside
      = do { dapEnv  <- loadOneModule dATA_ARRAY_PARALLEL_NAME      checkLoadDAP          paErr
           ; dappEnv <- loadOneModule dATA_ARRAY_PARALLEL_PRIM_NAME (goptM Opt_Vectorise) veErr
           ; updGblEnv (\env -> env {ds_dph_env = dapEnv `plusOccEnv` dappEnv }) thing_inside
           }
      where
        loadOneModule :: ModuleName           -- the module to load
                      -> DsM Bool             -- under which condition
                      -> MsgDoc              -- error message if module not found
                      -> DsM GlobalRdrEnv     -- empty if condition 'False'
        loadOneModule modname check err
          = do { doLoad <- check
               ; if not doLoad
                 then return emptyGlobalRdrEnv
                 else do {
               ; result <- liftIO $ findImportedModule hsc_env modname Nothing
               ; case result of
                   Found _ mod -> loadModule err mod
                   _           -> pprPgmError "Unable to use Data Parallel Haskell (DPH):" err
               } }

        paErr       = ptext (sLit "To use ParallelArrays,") <+> specBackend $$ hint1 $$ hint2
        veErr       = ptext (sLit "To use -fvectorise,") <+> specBackend $$ hint1 $$ hint2
        specBackend = ptext (sLit "you must specify a DPH backend package")
        hint1       = ptext (sLit "Look for packages named 'dph-lifted-*' with 'ghc-pkg'")
        hint2       = ptext (sLit "You may need to install them with 'cabal install dph-examples'")

    initDPHBuiltins thing_inside
      = do {   -- If '-XParallelArrays' given, we populate the builtin table for desugaring those
           ; doInitBuiltins <- checkLoadDAP
           ; if doInitBuiltins
             then dsInitPArrBuiltin thing_inside
             else thing_inside
           }

    checkLoadDAP = do { paEnabled <- xoptM Opt_ParallelArrays
                      ; return $ paEnabled &&
                                 mod /= gHC_PARR' &&
                                 moduleName mod /= dATA_ARRAY_PARALLEL_NAME
                      }
                      -- do not load 'Data.Array.Parallel' iff compiling 'base:GHC.PArr' or a
                      -- module called 'dATA_ARRAY_PARALLEL_NAME'; see also the comments at the top
                      -- of 'base:GHC.PArr' and 'Data.Array.Parallel' in the DPH libraries

initDsTc :: DsM a -> TcM a
initDsTc thing_inside
  = do  { this_mod <- getModule
        ; tcg_env  <- getGblEnv
        ; msg_var  <- getErrsVar
        ; dflags   <- getDynFlags
        ; static_binds_var <- liftIO $ newIORef []
        ; let type_env = tcg_type_env tcg_env
              rdr_env  = tcg_rdr_env tcg_env
              fam_inst_env = tcg_fam_inst_env tcg_env
              ds_envs  = mkDsEnvs dflags this_mod rdr_env type_env fam_inst_env
                                  msg_var static_binds_var
        ; setEnvs ds_envs thing_inside
        }

mkDsEnvs :: DynFlags -> Module -> GlobalRdrEnv -> TypeEnv -> FamInstEnv
         -> IORef Messages -> IORef [(Fingerprint, (Id, CoreExpr))]
         -> (DsGblEnv, DsLclEnv)
mkDsEnvs dflags mod rdr_env type_env fam_inst_env msg_var static_binds_var
  = let if_genv = IfGblEnv { if_rec_types = Just (mod, return type_env) }
        if_lenv = mkIfLclEnv mod (ptext (sLit "GHC error in desugarer lookup in") <+> ppr mod)
        gbl_env = DsGblEnv { ds_mod     = mod
                           , ds_fam_inst_env = fam_inst_env
                           , ds_if_env  = (if_genv, if_lenv)
                           , ds_unqual  = mkPrintUnqualified dflags rdr_env
                           , ds_msgs    = msg_var
                           , ds_dph_env = emptyGlobalRdrEnv
                           , ds_parr_bi = panic "DsMonad: uninitialised ds_parr_bi"
                           , ds_static_binds = static_binds_var
                           }
        lcl_env = DsLclEnv { dsl_meta = emptyNameEnv
                           , dsl_loc  = noSrcSpan
                           }
    in (gbl_env, lcl_env)

-- Attempt to load the given module and return its exported entities if successful.
--
loadModule :: SDoc -> Module -> DsM GlobalRdrEnv
loadModule doc mod
  = do { env    <- getGblEnv
       ; setEnvs (ds_if_env env) $ do
       { iface <- loadInterface doc mod ImportBySystem
       ; case iface of
           Failed err      -> pprPanic "DsMonad.loadModule: failed to load" (err $$ doc)
           Succeeded iface -> return $ mkGlobalRdrEnv . gresFromAvails prov . mi_exports $ iface
       } }
  where
    prov     = Imported [ImpSpec { is_decl = imp_spec, is_item = ImpAll }]
    imp_spec = ImpDeclSpec { is_mod = name, is_qual = True,
                             is_dloc = wiredInSrcSpan, is_as = name }
    name = moduleName mod

{-
************************************************************************
*                                                                      *
                Operations in the monad
*                                                                      *
************************************************************************

And all this mysterious stuff is so we can occasionally reach out and
grab one or more names.  @newLocalDs@ isn't exported---exported
functions are defined with it.  The difference in name-strings makes
it easier to read debugging output.
-}

-- Make a new Id with the same print name, but different type, and new unique
newUniqueId :: Id -> Type -> DsM Id
newUniqueId id = mkSysLocalM (occNameFS (nameOccName (idName id)))

duplicateLocalDs :: Id -> DsM Id
duplicateLocalDs old_local
  = do  { uniq <- newUnique
        ; return (setIdUnique old_local uniq) }

newPredVarDs :: PredType -> DsM Var
newPredVarDs pred
 = newSysLocalDs pred

newSysLocalDs, newFailLocalDs :: Type -> DsM Id
newSysLocalDs  = mkSysLocalM (fsLit "ds")
newFailLocalDs = mkSysLocalM (fsLit "fail")

newSysLocalsDs :: [Type] -> DsM [Id]
newSysLocalsDs tys = mapM newSysLocalDs tys

{-
We can also reach out and either set/grab location information from
the @SrcSpan@ being carried around.
-}

getGhcModeDs :: DsM GhcMode
getGhcModeDs =  getDynFlags >>= return . ghcMode

getSrcSpanDs :: DsM SrcSpan
getSrcSpanDs = do { env <- getLclEnv; return (dsl_loc env) }

putSrcSpanDs :: SrcSpan -> DsM a -> DsM a
putSrcSpanDs new_loc thing_inside = updLclEnv (\ env -> env {dsl_loc = new_loc}) thing_inside
warnDs :: SDoc -> DsM ()
warnDs warn = do { env <- getGblEnv
                 ; loc <- getSrcSpanDs
                 ; dflags <- getDynFlags
                 ; let msg = mkWarnMsg dflags loc (ds_unqual env)  warn
                 ; updMutVar (ds_msgs env) (\ (w,e) -> (w `snocBag` msg, e)) }

failWithDs :: SDoc -> DsM a
failWithDs err
  = do  { env <- getGblEnv
        ; loc <- getSrcSpanDs
        ; dflags <- getDynFlags
        ; let msg = mkErrMsg dflags loc (ds_unqual env) err
        ; updMutVar (ds_msgs env) (\ (w,e) -> (w, e `snocBag` msg))
        ; failM }

mkPrintUnqualifiedDs :: DsM PrintUnqualified
mkPrintUnqualifiedDs = ds_unqual <$> getGblEnv

instance {-# OVERLAPS #-} MonadThings (IOEnv (Env DsGblEnv DsLclEnv)) where
    lookupThing = dsLookupGlobal

dsLookupGlobal :: Name -> DsM TyThing
-- Very like TcEnv.tcLookupGlobal
dsLookupGlobal name
  = do  { env <- getGblEnv
        ; setEnvs (ds_if_env env)
                  (tcIfaceGlobal name) }

dsLookupGlobalId :: Name -> DsM Id
dsLookupGlobalId name
  = tyThingId <$> dsLookupGlobal name

-- |Get a name from "Data.Array.Parallel" for the desugarer, from the 'ds_parr_bi' component of the
-- global desugerar environment.
--
dsDPHBuiltin :: (PArrBuiltin -> a) -> DsM a
dsDPHBuiltin sel = (sel . ds_parr_bi) <$> getGblEnv

dsLookupTyCon :: Name -> DsM TyCon
dsLookupTyCon name
  = tyThingTyCon <$> dsLookupGlobal name

dsLookupDataCon :: Name -> DsM DataCon
dsLookupDataCon name
  = tyThingDataCon <$> dsLookupGlobal name

-- |Lookup a name exported by 'Data.Array.Parallel.Prim' or 'Data.Array.Parallel.Prim'.
--  Panic if there isn't one, or if it is defined multiple times.
dsLookupDPHRdrEnv :: OccName -> DsM Name
dsLookupDPHRdrEnv occ
  = liftM (fromMaybe (pprPanic nameNotFound (ppr occ)))
  $ dsLookupDPHRdrEnv_maybe occ
  where nameNotFound  = "Name not found in 'Data.Array.Parallel' or 'Data.Array.Parallel.Prim':"

-- |Lookup a name exported by 'Data.Array.Parallel.Prim' or 'Data.Array.Parallel.Prim',
--  returning `Nothing` if it's not defined. Panic if it's defined multiple times.
dsLookupDPHRdrEnv_maybe :: OccName -> DsM (Maybe Name)
dsLookupDPHRdrEnv_maybe occ
  = do { env <- ds_dph_env <$> getGblEnv
       ; let gres = lookupGlobalRdrEnv env occ
       ; case gres of
           []    -> return $ Nothing
           [gre] -> return $ Just $ gre_name gre
           _     -> pprPanic multipleNames (ppr occ)
       }
  where multipleNames = "Multiple definitions in 'Data.Array.Parallel' and 'Data.Array.Parallel.Prim':"


-- Populate 'ds_parr_bi' from 'ds_dph_env'.
--
dsInitPArrBuiltin :: DsM a -> DsM a
dsInitPArrBuiltin thing_inside
  = do { lengthPVar         <- externalVar (fsLit "lengthP")
       ; replicatePVar      <- externalVar (fsLit "replicateP")
       ; singletonPVar      <- externalVar (fsLit "singletonP")
       ; mapPVar            <- externalVar (fsLit "mapP")
       ; filterPVar         <- externalVar (fsLit "filterP")
       ; zipPVar            <- externalVar (fsLit "zipP")
       ; crossMapPVar       <- externalVar (fsLit "crossMapP")
       ; indexPVar          <- externalVar (fsLit "!:")
       ; emptyPVar          <- externalVar (fsLit "emptyP")
       ; appPVar            <- externalVar (fsLit "+:+")
       -- ; enumFromToPVar     <- externalVar (fsLit "enumFromToP")
       -- ; enumFromThenToPVar <- externalVar (fsLit "enumFromThenToP")
       ; enumFromToPVar     <- return arithErr
       ; enumFromThenToPVar <- return arithErr

       ; updGblEnv (\env -> env {ds_parr_bi = PArrBuiltin
                                              { lengthPVar         = lengthPVar
                                              , replicatePVar      = replicatePVar
                                              , singletonPVar      = singletonPVar
                                              , mapPVar            = mapPVar
                                              , filterPVar         = filterPVar
                                              , zipPVar            = zipPVar
                                              , crossMapPVar       = crossMapPVar
                                              , indexPVar          = indexPVar
                                              , emptyPVar          = emptyPVar
                                              , appPVar            = appPVar
                                              , enumFromToPVar     = enumFromToPVar
                                              , enumFromThenToPVar = enumFromThenToPVar
                                              } })
                   thing_inside
       }
  where
    externalVar :: FastString -> DsM Var
    externalVar fs = dsLookupDPHRdrEnv (mkVarOccFS fs) >>= dsLookupGlobalId

    arithErr = panic "Arithmetic sequences have to wait until we support type classes"

dsGetFamInstEnvs :: DsM FamInstEnvs
-- Gets both the external-package inst-env
-- and the home-pkg inst env (includes module being compiled)
dsGetFamInstEnvs
  = do { eps <- getEps; env <- getGblEnv
       ; return (eps_fam_inst_env eps, ds_fam_inst_env env) }

dsGetMetaEnv :: DsM (NameEnv DsMetaVal)
dsGetMetaEnv = do { env <- getLclEnv; return (dsl_meta env) }

dsLookupMetaEnv :: Name -> DsM (Maybe DsMetaVal)
dsLookupMetaEnv name = do { env <- getLclEnv; return (lookupNameEnv (dsl_meta env) name) }

dsExtendMetaEnv :: DsMetaEnv -> DsM a -> DsM a
dsExtendMetaEnv menv thing_inside
  = updLclEnv (\env -> env { dsl_meta = dsl_meta env `plusNameEnv` menv }) thing_inside

-- | Gets a reference to the SPT entries created so far.
dsGetStaticBindsVar :: DsM (IORef [(Fingerprint, (Id,CoreExpr))])
dsGetStaticBindsVar = fmap ds_static_binds getGblEnv

discardWarningsDs :: DsM a -> DsM a
-- Ignore warnings inside the thing inside;
-- used to ignore inaccessable cases etc. inside generated code
discardWarningsDs thing_inside
  = do  { env <- getGblEnv
        ; old_msgs <- readTcRef (ds_msgs env)

        ; result <- thing_inside

        -- Revert messages to old_msgs
        ; writeTcRef (ds_msgs env) old_msgs

        ; return result }
