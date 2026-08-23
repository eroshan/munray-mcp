-- {{SERVICE}} guarded integration tests
--
-- This file runs mutations only when MUNRAY_RUN_GUARDED=1. It must use a
-- tightly scoped fixture, deterministic resource names, and mandatory cleanup
-- even when an assertion fails. Keep all read-only coverage in
-- integration_tests.lua.

if os.getenv("MUNRAY_RUN_GUARDED") ~= "1" then
  return {
    __munray_test_status = "SKIPPED",
    reason = "set MUNRAY_RUN_GUARDED=1 to run guarded integration tests",
  }
end

assert(sys.test.set_mode("guarded"), "could not enable guarded test mode")

-- TODO: Replace this starter error with guarded mutation coverage. Use a
-- deterministic fixture name, clean it up in a finally-style protected call,
-- and fail if cleanup does not complete.
error("replace the guarded integration test before enabling MUNRAY_RUN_GUARDED")
