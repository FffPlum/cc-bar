# Host API SDK

Platform-neutral TypeScript client for the native host. It has no UI or React dependencies and does not calculate costs or cache business state. `costUSD` is a decimal string produced by the host. Usage ranges use ISO 8601 timestamps and are half-open (`from` inclusive, `to` exclusive); both must represent midnight in the host’s local calendar.

Create a `HostAPI` with an injected `Transport`. On macOS use `createMacOSTransport()` from `@ccbar/host-api/macos`; it owns the WebKit event callback until `dispose()`. Host requests time out after 15 seconds by default; `dispose()` rejects outstanding requests and releases subscriptions. A transport may be injected for other platforms or tests. Subscribe to invalidation events and re-fetch affected data; revisions are opaque strings. Platform availability and capabilities come from the host.

Run `npm ci && npm test` to compile and run the SDK tests. `fixtures/wire.json` is shared with native protocol tests.

A timeout or disposal stops the client waiting; it does not cancel a command already sent to the host. Check host state before retrying an action with side effects.
