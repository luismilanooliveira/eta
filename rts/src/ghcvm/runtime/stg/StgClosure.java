package ghcvm.runtime.closure;

import ghcvm.runtime.types.Capability;
import ghcvm.runtime.types.StgTSO;
import ghcvm.runtime.message.MessageBlackHole;

public abstract class StgClosure {
    public void enter(StgContext context) {}
    public void preEnter(StgContext context) {}
    public boolean isEvaluated() { return true; }
    public void thunkUpdate(Capability cap, StgTSO tso) {
        cap.checkBlockingQueues(tso);
    }
    public boolean blackHole(Capability cap, MessageBlackHole msg) { return false; }
    public boolean isTrecHeader() { return false; }
}