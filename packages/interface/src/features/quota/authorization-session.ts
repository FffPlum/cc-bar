// An authorization can start after its dialog has already been dismissed. Cancel
// once immediately, and again after the start request settles to cover both orders.
export class AuthorizationSession {
  private request: Promise<unknown> | null = null;
  private active = false;
  private stopping: Promise<void> | null = null;
  constructor(private readonly cancel: () => Promise<unknown>) {}
  async start(run: () => Promise<unknown>): Promise<void> {
    if (this.active || this.stopping) return;
    this.active = true;
    this.request = run();
    try {
      await this.request;
    } finally {
      this.request = null;
    }
  }
  track() {
    this.active = true;
  }
  complete() {
    this.active = false;
  }
  stop(): Promise<void> {
    if (this.stopping) return this.stopping;
    if (!this.active) return Promise.resolve();
    const request = this.request;
    this.stopping = (async () => {
      if (request) {
        await Promise.allSettled([this.cancel(), request]);
      }
      await this.cancel();
      this.active = false;
    })().finally(() => {
      this.stopping = null;
    });
    return this.stopping;
  }
}
