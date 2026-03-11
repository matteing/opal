export interface ServerResolution {
    /** Command to spawn (binary path or executable name) */
    command: string;
    /** Arguments to pass to the command */
    args: string[];
    /** Working directory for the spawned process */
    cwd?: string;
}
/**
 * Resolve the opal-server binary.
 *
 * 0. Monorepo dev mode via `mise exec` (when running from source tree)
 * 1. `opal-server` in PATH (user-installed or dev build)
 * 2. Extracted OTP release at ~/.opal/erts/<version>/
 */
export declare function resolveServer(): ServerResolution;
//# sourceMappingURL=resolve.d.ts.map