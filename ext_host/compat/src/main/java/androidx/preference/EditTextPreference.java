package androidx.preference;

import android.content.Context;
import android.widget.EditText;

public class EditTextPreference extends DialogPreference {
    public interface OnBindEditTextListener {
        void onBindEditText(EditText editText);
    }

    private String text;
    private OnBindEditTextListener onBindEditTextListener;

    public EditTextPreference(Context context) {
        super(context);
    }

    public String getText() { return text; }

    public void setText(String text) {
        this.text = text;
        persistString(text);
    }

    public void setOnBindEditTextListener(OnBindEditTextListener listener) { this.onBindEditTextListener = listener; }
    public OnBindEditTextListener getOnBindEditTextListener() { return onBindEditTextListener; }

    @Override
    protected void onSetInitialValue(Object defaultValue) {
        setText(getPersistedString(defaultValue != null ? defaultValue.toString() : null));
    }
}
