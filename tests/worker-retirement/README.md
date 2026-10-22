# Worker retirement on the phone integration branch

This ports `094d3b91fae26890a315357630b28c8b4cdab500` to the existing Herdr pool on `cdd1b82bd2cf5ded650477cf2c96fb1bbe01b12f`. The phone base predates the public worker termination RPC, so this port includes that prerequisite. It preserves the existing terminal-control export and bundled worker identities.

A released worker retains its process assertion until its spawn-reply PID exits, or until a two-second deadline. Retiring slots count against the bundled capacity. Admission waits while a slot retires; a fully active pool returns ENOSPC. Failed admission terminates the worker while preserving the original error.

`reuse-check.m` exercises the public `herdr_pane_spawn` / `herdr_pane_release` boundary from an app command. Build it as a command framework and register `reuse-check` only in a disposable Simulator app. The production app needs no test command or test flag.

For the reuse test, replace `terminate:` only in a disposable build with XPC invalidation followed by SIGKILL after 750 ms. Run `reuse-check`: the previous PID must still exist at release, while the replacement uses a different PID. With the disposable app's `HerdrWorkerCount` set to 1, admission must wait until the previous PID has exited. Run the same fixture on the parent to establish RED.

At capacity 1, `reuse-check failure` supplies invalid environment input, expects EINVAL, then requires valid admission within two seconds. Restore the production worker source before committing or handing the branch to the phone build owner.

The build owner must rebuild the host's `RemotePane.o` from this revision. The existing phone recipe pins a prebuilt object and native-source inventory; both input pins must be refreshed together. Reusing the old object omits observation and termination from the app even when its Swift source is current.
