package android.webkit;

public class ConsoleMessage {
    private final String message;
    private final String sourceId;
    private final int lineNumber;

    public ConsoleMessage(String message, String sourceId, int lineNumber) {
        this.message = message;
        this.sourceId = sourceId;
        this.lineNumber = lineNumber;
    }

    public String message() { return message; }
    public String sourceId() { return sourceId; }
    public int lineNumber() { return lineNumber; }
}
