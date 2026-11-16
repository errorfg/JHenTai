/** Creates the JVM if needed and starts the extension host; resolves with its port. */
export const start: (javaHome: string, jar: string, tmpDir: string, userHome: string, config: string) => Promise<number>;
/** Opens the host's port again; resolves with the port, or -1. */
export const restartServer: () => Promise<number>;
