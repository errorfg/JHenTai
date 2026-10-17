package android.widget;

import android.content.Context;
import android.view.View;

public class TextView extends View {
    private CharSequence text = "";
    private CharSequence hint;

    public TextView(Context context) {
        super(context);
    }

    public void setText(CharSequence text) { this.text = text; }
    public CharSequence getText() { return text; }
    public void setHint(CharSequence hint) { this.hint = hint; }
    public CharSequence getHint() { return hint; }
    public void setInputType(int type) { }
    public void setSingleLine(boolean singleLine) { }
    public void setSingleLine() { }
    public void setMaxLines(int maxLines) { }
    public void setSelection(int index) { }
}
