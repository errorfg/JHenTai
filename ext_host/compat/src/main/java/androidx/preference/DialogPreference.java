package androidx.preference;

import android.content.Context;

public abstract class DialogPreference extends Preference {
    private CharSequence dialogTitle;
    private CharSequence dialogMessage;

    public DialogPreference(Context context) {
        super(context);
    }

    public CharSequence getDialogTitle() { return dialogTitle; }
    public void setDialogTitle(CharSequence dialogTitle) { this.dialogTitle = dialogTitle; }
    public CharSequence getDialogMessage() { return dialogMessage; }
    public void setDialogMessage(CharSequence dialogMessage) { this.dialogMessage = dialogMessage; }
    public void setPositiveButtonText(CharSequence text) { }
    public void setNegativeButtonText(CharSequence text) { }
}
