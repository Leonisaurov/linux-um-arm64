package org.umarm.debian;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbManager;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.system.Os;
import android.system.OsConstants;
import android.text.InputType;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import com.termux.terminal.TerminalSession;
import com.termux.terminal.TerminalSessionClient;
import com.termux.view.TerminalView;
import com.termux.view.TerminalViewClient;

import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.BufferedReader;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.zip.GZIPInputStream;

/**
 * A Linux kernel, running inside an ordinary Android app, on a real terminal.
 *
 * The console used to be a TextView and a single-line input box, which could
 * show a boot log and nothing else -- no ANSI, no cursor addressing, no line
 * editing, so no interactive program could run. The terminal is now the one
 * from Termux (vendored under com/termux/terminal and com/termux/view), which
 * means the guest console is a genuine vt: the kernel talks to a pseudoterminal
 * (com/termux/terminal/JNI, a copy of Termux's jni/termux.c), the emulator
 * interprets the escapes, and the guest's shell, vi and top behave the way they
 * do in Termux itself.
 *
 * The differences that shape the rest of the class remain the app sandbox's:
 *
 *   - The app runs in the untrusted_app SELinux domain under a W^X policy. It
 *     may not execute anything it wrote itself, so every binary -- the kernel,
 *     the stub, passt, umnet, umusb -- ships as a lib*.so inside the APK and is
 *     run from getApplicationInfo().nativeLibraryDir, the one directory an app
 *     may execute from. libtermux.so is the exception that proves the rule: it
 *     is an ordinary shared library, loaded into this process rather than exec'd.
 *   - UML normally execs its stub from an anonymous memfd. That is refused here,
 *     so the kernel is passed stub_exe=<nativeLibraryDir>/libstub.so.
 *   - There is no /tmp. Guest RAM is backed from the app's cache directory.
 *   - The pty is how the guest gets a tty: createSubprocess() opens /dev/ptmx,
 *     forks and execs the kernel (or the umnet wrapper in front of it) with the
 *     pty slave as fd 0/1/2, so con0=fd:0,fd:1 is a terminal and SIGWINCH and
 *     TIOCSWINSZ do what they should.
 */
public class MainActivity extends Activity implements TerminalViewClient, TerminalSessionClient {

    private static final String TAG = "umarm";

    /*
     * Bumped when the bundled guest image changes. The image's file name is
     * fixed and the app unpacks it once, so without this an image fix would
     * reach only a fresh install: rootfs.revision records what was unpacked,
     * and a mismatch replaces the image and runs the first-run setup again.
     */
    private static final String ROOTFS_REVISION = "2";

    private TerminalView terminalView;
    private Button startStop;
    private Button ctrlKey;
    private Button altKey;
    private HorizontalScrollView keysScroll;

    /* Extra-key state, read by the view for the soft keyboard. */
    private boolean mCtrl, mAlt, mShift, mFn;

    private int fontSizeSp = 12;

    /* Settings, persisted so a reboot of the guest does not lose them. */
    private EditText memField;
    private CheckBox seccompBox;
    private CheckBox netBox;
    private CheckBox usbBox;
    private SharedPreferences prefs;

    private TerminalSession session;
    private int shellPid = -1;

    private final Handler ui = new Handler(Looper.getMainLooper());

    /*
     * Deliberately one level of anonymous class, not two: a Runnable posting
     * another Runnable produces a MainActivity$N$1 class file that d8 8.2
     * rejects with an internal NullPointerException, which reads like a
     * compiler bug rather than anything to do with this code.
     */
    private FileOutputStream logFile;

    @Override
    protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        prefs = getPreferences(MODE_PRIVATE);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.BLACK);

        /* --- top bar: boot/stop, extra keys, settings --- */
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);

        startStop = new Button(this);
        startStop.setText("Boot");
        startStop.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                if (isGuestRunning()) stopGuest(); else boot();
            }
        });
        bar.addView(startStop, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1.0f));

        Button keysButton = new Button(this);
        keysButton.setText("Keys");
        keysButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                keysScroll.setVisibility(keysScroll.getVisibility() == View.VISIBLE
                        ? View.GONE : View.VISIBLE);
            }
        });
        bar.addView(keysButton, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1.0f));

        Button settingsButton = new Button(this);
        settingsButton.setText("Settings");
        settingsButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { showSettings(); }
        });
        bar.addView(settingsButton, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1.0f));

        root.addView(bar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        /* --- the terminal --- */
        fontSizeSp = prefs.getInt("font", 12);
        terminalView = new TerminalView(this, null);
        terminalView.setTerminalViewClient(this);
        terminalView.setFocusable(true);
        terminalView.setFocusableInTouchMode(true);
        terminalView.setTextSize(fontSizeSp);
        root.addView(terminalView, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1.0f));

        /* --- extra keys --- */
        keysScroll = new HorizontalScrollView(this);
        LinearLayout keysRow = new LinearLayout(this);
        keysRow.setOrientation(LinearLayout.HORIZONTAL);

        ctrlKey = addKey(keysRow, "CTRL", new Runnable() {
            @Override public void run() { mCtrl = !mCtrl; paintModifiers(); }
        });
        altKey = addKey(keysRow, "ALT", new Runnable() {
            @Override public void run() { mAlt = !mAlt; paintModifiers(); }
        });
        addKey(keysRow, "SHIFT", new Runnable() {
            @Override public void run() { mShift = !mShift; paintModifiers(); }
        });
        addKey(keysRow, "FN", new Runnable() {
            @Override public void run() { mFn = !mFn; paintModifiers(); }
        });
        addKey(keysRow, "ESC", new Runnable() {
            @Override public void run() { writeToSession("\u001b"); }
        });
        addKey(keysRow, "TAB", new Runnable() {
            @Override public void run() { writeToSession("\t"); }
        });
        addKey(keysRow, "^C", new Runnable() {
            @Override public void run() { writeToSession("\u0003"); }
        });
        addKey(keysRow, "^D", new Runnable() {
            @Override public void run() { writeToSession("\u0004"); }
        });
        addKey(keysRow, "\u2191", new Runnable() {
            @Override public void run() { writeToSession("\u001b[A"); }
        });
        addKey(keysRow, "\u2193", new Runnable() {
            @Override public void run() { writeToSession("\u001b[B"); }
        });
        addKey(keysRow, "\u2192", new Runnable() {
            @Override public void run() { writeToSession("\u001b[C"); }
        });
        addKey(keysRow, "\u2190", new Runnable() {
            @Override public void run() { writeToSession("\u001b[D"); }
        });
        addKey(keysRow, "/", new Runnable() {
            @Override public void run() { writeToSession("/"); }
        });
        addKey(keysRow, "-", new Runnable() {
            @Override public void run() { writeToSession("-"); }
        });
        addKey(keysRow, "|", new Runnable() {
            @Override public void run() { writeToSession("|"); }
        });
        addKey(keysRow, "~", new Runnable() {
            @Override public void run() { writeToSession("~"); }
        });
        addKey(keysRow, "PASTE", new Runnable() {
            @Override public void run() { paste(); }
        });

        keysScroll.addView(keysRow);
        root.addView(keysScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        setContentView(root);

        loadSettings();
        paintModifiers();

        log("umarm -- Linux/UML on aarch64, Termux terminal, inside an Android app\n");
        log("uid " + android.os.Process.myUid() + " libdir "
                + getApplicationInfo().nativeLibraryDir + "\n");

        usbAttachNotice(getIntent());

        showKeyboardSoon();
    }

    /*
     * singleTop in the manifest, so plugging the adapter in while the guest is
     * running delivers the attach intent here instead of stacking a second
     * Activity on top of a boot in progress.
     */
    @Override
    protected void onNewIntent(Intent i) {
        super.onNewIntent(i);
        setIntent(i);
        usbAttachNotice(i);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (terminalView != null && terminalView.mEmulator != null)
            terminalView.onScreenUpdated();
    }

    @Override
    protected void onDestroy() {
        if (isFinishing()) stopGuest();
        super.onDestroy();
    }

    private Button addKey(LinearLayout row, String label, final Runnable action) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setPadding(24, 8, 24, 8);
        b.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { action.run(); }
        });
        row.addView(b);
        return b;
    }

    private void paintModifiers() {
        ctrlKey.setBackgroundColor(mCtrl ? Color.rgb(0, 96, 0) : Color.TRANSPARENT);
        altKey.setBackgroundColor(mAlt ? Color.rgb(0, 96, 0) : Color.TRANSPARENT);
        /* SHIFT and FN have no dedicated button handle; their state is read by
         * the view through readShiftKey()/readFnKey(). */
    }

    private void writeToSession(String s) {
        if (session == null || !session.isRunning()) {
            toast("guest is not running");
            return;
        }
        session.write(s);
        terminalView.onScreenUpdated();
    }

    private void paste() {
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm == null || !cm.hasPrimaryClip()) {
            toast("clipboard is empty");
            return;
        }
        CharSequence t = cm.getPrimaryClip().getItemAt(0).getText();
        if (t != null) writeToSession(t.toString());
    }

    private void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_SHORT).show();
    }

    private void showKeyboardSoon() {
        ui.postDelayed(new Runnable() {
            @Override public void run() { showKeyboard(); }
        }, 300);
    }

    private void showKeyboard() {
        InputMethodManager imm =
                (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null)
            imm.showSoftInput(terminalView, InputMethodManager.SHOW_IMPLICIT);
    }

    /* ------------------------------------------------------------------
     * Settings
     * ------------------------------------------------------------------ */

    private void loadSettings() {
        memField = new EditText(this);
        memField.setInputType(InputType.TYPE_CLASS_NUMBER);
        memField.setText(prefs.getString("mem", "512"));

        seccompBox = new CheckBox(this);
        seccompBox.setText("seccomp");
        seccompBox.setChecked(prefs.getBoolean("seccomp", true));

        netBox = new CheckBox(this);
        netBox.setText("net (umnet + passt)");
        netBox.setChecked(prefs.getBoolean("net", true));

        /*
         * Off by default: most runs have nothing plugged into the phone, and the
         * USB path costs a permission dialog before the guest starts.
         */
        usbBox = new CheckBox(this);
        usbBox.setText("usb (RTL8811AU passthrough, needs net)");
        usbBox.setChecked(prefs.getBoolean("usb", false));
    }

    private void showSettings() {
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.VERTICAL);
        v.setPadding(32, 16, 32, 16);

        LinearLayout memRow = new LinearLayout(this);
        memRow.setOrientation(LinearLayout.HORIZONTAL);
        memRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView l = new TextView(this);
        l.setText("Guest RAM (MB)   ");
        memRow.addView(l);
        memRow.addView(memField);
        v.addView(memRow);

        v.addView(seccompBox);
        v.addView(netBox);
        v.addView(usbBox);

        Button probe = new Button(this);
        probe.setText("Probe app seccomp filter");
        probe.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View w) { runProbe(); }
        });
        v.addView(probe);

        new AlertDialog.Builder(this)
                .setTitle("umarm")
                .setView(v)
                .setPositiveButton("Save", new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface d, int which) {
                        prefs.edit()
                                .putString("mem", memField.getText().toString())
                                .putBoolean("seccomp", seccompBox.isChecked())
                                .putBoolean("net", netBox.isChecked())
                                .putBoolean("usb", usbBox.isChecked())
                                .apply();
                    }
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    /* ------------------------------------------------------------------
     * Booting the guest
     * ------------------------------------------------------------------ */

    private boolean isGuestRunning() {
        return session != null && session.isRunning();
    }

    private void boot() {
        startStop.setText("Stop");
        log("\n[boot]\n");

        String libdir = getApplicationInfo().nativeLibraryDir;
        File kernel = new File(libdir, "libuml.so");
        File stub = new File(libdir, "libstub.so");
        File umnet = new File(libdir, "libumnet.so");
        File passt = new File(libdir, "libpasst.so");
        File umusb = new File(libdir, "libumusb.so");

        if (!kernel.exists()) {
            fail("ERROR: " + kernel + " missing from the APK");
            return;
        }
        if (!stub.exists()) {
            fail("ERROR: " + stub + " missing from the APK");
            return;
        }

        File initrd = null;
        File rootfs = null;
        try {
            rootfs = unpackAsset("rootfs.ext4.gz", "rootfs.ext4");
        } catch (IOException e) {
            /* Optional: the image is what carries docker and persistence; the
             * initramfs is the fallback that always ships. */
        }
        if (rootfs == null) {
            try {
                initrd = unpackAsset("initramfs.cpio.gz", "initramfs.cpio.gz");
            } catch (IOException e) {
                fail("ERROR: neither rootfs.ext4.gz nor initramfs.cpio.gz in the APK: " + e);
                return;
            }
        }

        int usbfd = -1;
        if (usbBox.isChecked()) {
            if (!umusb.exists())
                log("usb: libumusb.so is not in this build; booting without USB\n");
            else
                usbfd = usbOpen();
        }

        List<String> args = new ArrayList<String>();
        args.add("mem=" + memField.getText().toString() + "M");
        args.add("panic=-1");
        args.add("con=null");
        args.add("con0=fd:0,fd:1");
        args.add("stub_exe=" + stub.getAbsolutePath());
        args.add("seccomp=" + (seccompBox.isChecked() ? "auto" : "off"));
        if (rootfs != null && rootfs.exists()) {
            args.add("ubd0=" + rootfs.getAbsolutePath());
            args.add("root=/dev/ubda");
            args.add("rw");
            args.add("init=/umarm-init");
            args.add("umarm.share=" + getFilesDir().getAbsolutePath());
        } else {
            args.add("initrd=" + initrd.getAbsolutePath());
            args.add("init=/init");
        }

        /*
         * umnet and umusb are wrappers: each execs whatever follows its own --,
         * so the kernel ends up under both. The terminal's pty provider runs the
         * first one as its "shell". The usbfs descriptor is handed to umusb over
         * an abstract socket (SCM_RIGHTS) rather than inherited, because the pty
         * provider closes every descriptor above stderr in the child.
         */
        boolean net = netBox.isChecked() && umnet.exists() && passt.exists();
        String cmd;
        String[] argv;
        if (net) {
            cmd = umnet.getAbsolutePath();
            List<String> a = new ArrayList<String>();
            a.add(umnet.getAbsolutePath());
            a.add("--passt");
            a.add(passt.getAbsolutePath());
            a.add("--");
            a.add(kernel.getAbsolutePath());
            a.addAll(args);
            argv = a.toArray(new String[0]);
        } else {
            cmd = kernel.getAbsolutePath();
            List<String> a = new ArrayList<String>();
            a.add(kernel.getAbsolutePath());
            a.addAll(args);
            argv = a.toArray(new String[0]);
        }

        if (usbfd >= 0) {
            String sock = "umarm-usb-" + android.os.Process.myPid();
            usbServe(sock);
            List<String> a = new ArrayList<String>();
            a.add(umusb.getAbsolutePath());
            a.add("--usbsock");
            a.add(sock);
            a.add("--listen");
            a.add("127.0.0.1:3240");
            a.add("--");
            a.add(cmd);
            for (int i = 1; i < argv.length; i++) a.add(argv[i]);
            cmd = umusb.getAbsolutePath();
            argv = a.toArray(new String[0]);
        }

        log("$ " + join(argv) + "\n");

        String[] env = {
                "PATH=/system/bin:/system/xbin",
                "HOME=" + getFilesDir().getAbsolutePath(),
                "TMPDIR=" + getCacheDir().getAbsolutePath(),
                "TERM=xterm-256color",
                "LANG=en_US.UTF-8",
                "ANDROID_ROOT=/system",
                "ANDROID_DATA=/data",
        };

        try {
            /*
             * A fresh session per boot. transcriptRows is finite: the emulator's
             * scrollback is RAM, and a kernel that prints for an hour should not
             * be able to exhaust it.
             */
            session = new TerminalSession(cmd, getFilesDir().getAbsolutePath(),
                    argv, env, 2000, this);
            terminalView.attachSession(session);
            terminalView.requestFocus();
            showKeyboardSoon();
        } catch (Exception e) {
            fail("ERROR: could not start the guest: " + e);
        }
    }

    private void stopGuest() {
        if (session != null) {
            if (session.isRunning()) session.finishIfRunning();
        }
        session = null;
        startStop.setText("Boot");
        usbRelease();
    }

    private void fail(String s) {
        log(s + "\n");
        toast(s);
        startStop.setText("Boot");
    }

    /* ------------------------------------------------------------------
     * TerminalSessionClient
     * ------------------------------------------------------------------ */

    @Override public void onTextChanged(TerminalSession changedSession) {
        terminalView.onScreenUpdated();
    }

    @Override public void onTitleChanged(TerminalSession changedSession) {
        setTitle(changedSession.getTitle() != null ? changedSession.getTitle() : "umarm");
    }

    @Override public void onSessionFinished(TerminalSession finishedSession) {
        log("[guest exited]\n");
        startStop.setText("Boot");
        usbRelease();
    }

    @Override public void onCopyTextToClipboard(TerminalSession s, String text) {
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("umarm", text));
    }

    @Override public void onPasteTextFromClipboard(TerminalSession s) {
        paste();
    }

    @Override public void onBell(TerminalSession s) { }

    @Override public void onColorsChanged(TerminalSession s) { }

    @Override public void onTerminalCursorStateChange(boolean state) { }

    @Override public void setTerminalShellPid(TerminalSession s, int pid) {
        shellPid = pid;
    }

    @Override public Integer getTerminalCursorStyle() {
        return null;
    }

    /* ------------------------------------------------------------------
     * TerminalViewClient
     * ------------------------------------------------------------------ */

    @Override public float onScale(float scale) {
        if (scale < 0.9f || scale > 1.1f) {
            boolean increase = scale > 1.f;
            int old = fontSizeSp;
            fontSizeSp = Math.max(6, Math.min(32, increase ? fontSizeSp + 1 : fontSizeSp - 1));
            if (fontSizeSp != old) {
                terminalView.setTextSize(fontSizeSp);
                prefs.edit().putInt("font", fontSizeSp).apply();
            }
            return 1.0f;
        }
        return scale;
    }

    @Override public void onSingleTapUp(MotionEvent e) {
        showKeyboard();
    }

    @Override public boolean shouldBackButtonBeMappedToEscape() { return false; }

    @Override public boolean shouldEnforceCharBasedInput() { return true; }

    @Override public boolean shouldUseCtrlSpaceWorkaround() { return false; }

    @Override public boolean isTerminalViewSelected() { return true; }

    @Override public void copyModeChanged(boolean copyMode) { }

    @Override public boolean onKeyDown(int keyCode, KeyEvent e, TerminalSession s) {
        /* The back button leaves the guest alone; it is the only way out of the
         * Activity and mapping it to Escape would strand the user. */
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            return false;
        }
        return false;
    }

    @Override public boolean onKeyUp(int keyCode, KeyEvent e) { return false; }

    @Override public boolean onLongPress(MotionEvent event) { return false; }

    @Override public boolean readControlKey() { return mCtrl; }

    @Override public boolean readAltKey() { return mAlt; }

    @Override public boolean readShiftKey() { return mShift; }

    @Override public boolean readFnKey() { return mFn; }

    @Override public boolean onCodePoint(int codePoint, boolean ctrlDown, TerminalSession s) {
        /* Let the terminal handle it; the modifier toggles are already folded
         * into ctrlDown by TerminalView before the call. */
        return false;
    }

    @Override public void onEmulatorSet() { }

    @Override public void logError(String tag, String message) { log("E " + tag + ": " + message + "\n"); }
    @Override public void logWarn(String tag, String message)  { log("W " + tag + ": " + message + "\n"); }
    @Override public void logInfo(String tag, String message)  { Log.i(tag, message); }
    @Override public void logDebug(String tag, String message) { Log.d(tag, message); }
    @Override public void logVerbose(String tag, String message) { Log.v(tag, message); }
    @Override public void logStackTraceWithMessage(String tag, String message, Exception e) {
        log("E " + tag + ": " + message + " " + e + "\n");
    }
    @Override public void logStackTrace(String tag, Exception e) {
        log("E " + tag + ": " + e + "\n");
    }

    /* ------------------------------------------------------------------
     * Logging. The terminal shows the guest; this is the app's own record,
     * because the interesting part of a failed boot is usually gone from a
     * phone screen by the time someone looks.
     * ------------------------------------------------------------------ */

    private void log(String s) {
        try {
            if (logFile == null)
                logFile = new FileOutputStream(new File(getFilesDir(), "boot.log"), true);
            logFile.write(s.getBytes("UTF-8"));
            logFile.flush();
        } catch (Exception e) {
            /* Never let logging break the boot it is meant to record. */
        }
    }

    private static String join(String[] argv) {
        StringBuilder b = new StringBuilder();
        for (String s : argv) { b.append(s); b.append(' '); }
        return b.toString().trim();
    }

    /**
     * Unpack a gzipped asset once, into the app's private files directory.
     * Data, not code -- so it may live here; it just may not be executed.
     */
    private File unpackAsset(String asset, String outName) throws IOException {
        File out = new File(getFilesDir(), outName);
        File rev = "rootfs.ext4".equals(outName)
                ? new File(getFilesDir(), "rootfs.revision") : null;

        if (out.exists() && out.length() > 0) {
            if (rev == null || ROOTFS_REVISION.equals(firstLine(rev)))
                return out;
            log("the bundled image changed (" + firstLine(rev) + " -> "
                    + ROOTFS_REVISION + "); unpacking it again\n");
            if (!out.delete())
                throw new IOException("cannot replace " + out);
        }

        toast("unpacking " + asset + " ...");
        InputStream in = getAssets().open(asset);
        if (asset.endsWith(".gz"))
            in = new GZIPInputStream(in, 65536);
        FileOutputStream fos = new FileOutputStream(out);
        byte[] buf = new byte[1 << 16];
        long total = 0;
        int n;
        while ((n = in.read(buf)) > 0) {
            fos.write(buf, 0, n);
            total += n;
        }
        fos.close();
        in.close();
        log("unpacked " + asset + " (" + (total >> 20) + " MB)\n");

        if (rev != null) {
            FileOutputStream r = new FileOutputStream(rev);
            r.write((ROOTFS_REVISION + "\n").getBytes("UTF-8"));
            r.close();

            /*
             * A freshly unpacked guest image is a fresh install, and the
             * guest's init reads this file to offer first-run setup -- it
             * creates the non-root user and, from then on, logs in as it. It is
             * written here and not baked into the image so that the wizard is an
             * app boot: the image the harness and the CI gates boot has no
             * marker, and neither does the second boot, because the guest
             * removes it.
             */
            File marker = new File(getFilesDir(), "first-run");
            if (!marker.exists() && !marker.createNewFile())
                log("cannot create the first-run marker; the guest boots as root\n");
        }
        return out;
    }

    /** First line of a small text file, or "" when it is missing or unreadable. */
    private static String firstLine(File f) {
        try {
            BufferedReader r = new BufferedReader(new InputStreamReader(
                    new FileInputStream(f), "UTF-8"));
            try {
                String s = r.readLine();
                return s == null ? "" : s.trim();
            } finally {
                r.close();
            }
        } catch (IOException e) {
            return "";
        }
    }

    /**
     * Run the seccomp probe, if this build has one.
     *
     * The seccomp filter zygote installs on this app is inherited by every
     * process it spawns, including the kernel -- which is why the guest can die
     * with SIGSYS here but not under `run-as`. The probe runs under that same
     * filter and reports which syscalls it forbids, because "something was
     * denied" is not something you can act on.
     */
    private void runProbe() {
        new Thread(new ProbeRunner()).start();
    }

    private final class ProbeRunner implements Runnable {
        @Override public void run() {
            try {
                File p = new File(getApplicationInfo().nativeLibraryDir, "libappseccomp.so");
                if (!p.exists()) {
                    toast("probe not in this build");
                    return;
                }
                File k = new File(getApplicationInfo().nativeLibraryDir, "libuml.so");
                File probe = new File(getApplicationInfo().nativeLibraryDir, "libprobe.so");
                ProcessBuilder pb = probe.exists()
                        ? new ProcessBuilder(probe.getAbsolutePath())
                        : new ProcessBuilder(p.getAbsolutePath(), k.getAbsolutePath(), "--version");
                pb.redirectErrorStream(true);
                Process pr = pb.start();
                BufferedReader r = new BufferedReader(
                        new InputStreamReader(pr.getInputStream()), 8192);
                String line;
                while ((line = r.readLine()) != null)
                    log("[probe] " + line + "\n");
                log("[probe exited " + pr.waitFor() + "]\n");
            } catch (Exception e) {
                log("probe error: " + e + "\n");
            }
        }
    }

    /* ------------------------------------------------------------------
     * USB passthrough.
     *
     * An app may not open /dev/bus/usb -- the untrusted_app domain has no
     * access to the device nodes at all. What it may do is ask the user for
     * permission to one device and be handed an already-open usbfs descriptor
     * for it, and USBDEVFS_* ioctls work on that descriptor. libusb reaches
     * Android hardware the same way (libusb_wrap_sys_device); umusb uses it to
     * serve USB/IP to the guest's vhci-hcd.
     * ------------------------------------------------------------------ */

    /*
     * The Realtek RTL8811AU that the guest's in-tree rtw88 8821au driver binds.
     * res/xml/device_filter.xml carries the same pair in decimal, 9047/287, and
     * the two have to be changed together.
     */
    private static final int USB_VENDOR = 0x2357;
    private static final int USB_PRODUCT = 0x011f;

    private static final String ACTION_USB_PERMISSION =
            "org.umarm.debian.USB_PERMISSION";

    private volatile CountDownLatch usbGrant;
    private ParcelFileDescriptor usbPfd;
    private LocalServerSocket usbServer;

    private final class UsbPermission extends BroadcastReceiver {
        @Override public void onReceive(Context c, Intent i) {
            CountDownLatch l = usbGrant;
            if (l != null) l.countDown();
        }
    }

    private static String usbId(int vendor, int product) {
        return String.format(Locale.US, "%04x:%04x", vendor, product);
    }

    private static String usbId(UsbDevice d) {
        return usbId(d.getVendorId(), d.getProductId());
    }

    private int usbOpen() {
        usbRelease();

        UsbManager um = (UsbManager) getSystemService(Context.USB_SERVICE);
        if (um == null) {
            log("usb: no UsbManager -- this phone has no USB host mode\n");
            return -1;
        }

        UsbDevice dev = null;
        HashMap<String, UsbDevice> devs = um.getDeviceList();
        for (UsbDevice d : devs.values()) {
            log("usb: sees " + usbId(d) + " " + d.getDeviceName() + "\n");
            if (d.getVendorId() == USB_VENDOR && d.getProductId() == USB_PRODUCT)
                dev = d;
        }
        if (dev == null) {
            log("usb: no " + usbId(USB_VENDOR, USB_PRODUCT) + " adapter among "
                    + devs.size() + " attached device(s); booting without USB\n");
            return -1;
        }

        if (!um.hasPermission(dev)) {
            log("usb: asking for permission to " + usbId(dev) + " ...\n");
            usbGrant = new CountDownLatch(1);
            UsbPermission recv = new UsbPermission();
            IntentFilter filter = new IntentFilter(ACTION_USB_PERMISSION);
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                    registerReceiver(recv, filter, Context.RECEIVER_NOT_EXPORTED);
                else
                    registerReceiver(recv, filter);

                try {
                    Intent i = new Intent(ACTION_USB_PERMISSION).setPackage(getPackageName());
                    int flags = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
                            ? PendingIntent.FLAG_IMMUTABLE : 0;
                    um.requestPermission(dev, PendingIntent.getBroadcast(this, 0, i, flags));
                    if (!usbGrant.await(60, TimeUnit.SECONDS))
                        log("usb: the permission dialog went unanswered for 60s\n");
                } finally {
                    unregisterReceiver(recv);
                }
            } catch (Exception e) {
                log("usb: permission request failed: " + e + "\n");
                usbGrant = null;
                return -1;
            } finally {
                usbGrant = null;
            }

            if (!um.hasPermission(dev)) {
                log("usb: permission denied; booting without USB\n");
                return -1;
            }
            log("usb: permission granted\n");
        }

        UsbDeviceConnection conn = um.openDevice(dev);
        if (conn == null) {
            log("usb: openDevice(" + usbId(dev) + ") failed -- unplugged since the scan?\n");
            return -1;
        }
        try {
            ParcelFileDescriptor theirs =
                    ParcelFileDescriptor.adoptFd(conn.getFileDescriptor());
            try {
                usbPfd = ParcelFileDescriptor.dup(theirs.getFileDescriptor());
            } finally {
                theirs.detachFd();
            }
            Os.fcntlInt(usbPfd.getFileDescriptor(), OsConstants.F_SETFD, 0);
        } catch (Exception e) {
            log("usb: cannot take over the descriptor: " + e + "\n");
            usbRelease();
            conn.close();
            return -1;
        }
        conn.close();

        int fd = usbPfd.getFd();
        log("usb: " + usbId(dev) + " " + dev.getDeviceName() + " opened, fd " + fd + "\n");
        return fd;
    }

    /*
     * Hand the usbfs descriptor to umusb over an abstract unix socket.
     *
     * The pty provider closes every descriptor above stderr in the child before
     * exec, so a descriptor this app opens cannot be inherited by number.
     * SCM_RIGHTS installs a fresh one in umusb's table instead.
     */
    private void usbServe(final String name) {
        try {
            usbServer = new LocalServerSocket(name);
        } catch (IOException e) {
            log("usb: cannot listen on @" + name + ": " + e + "\n");
            return;
        }
        new Thread(new UsbServer(name)).start();
    }

    private final class UsbServer implements Runnable {
        private final String name;

        UsbServer(String name) { this.name = name; }

        @Override public void run() {
            try {
                LocalSocket s = usbServer.accept();
                FileDescriptor[] fds = { usbPfd.getFileDescriptor() };
                s.setFileDescriptorsForSend(fds);
                s.getOutputStream().write(0);
                s.getOutputStream().flush();
                s.close();
                log("usb: descriptor sent to umusb\n");
            } catch (Exception e) {
                log("usb: handing over the descriptor failed: " + e + "\n");
            }
        }
    }

    private void usbRelease() {
        if (usbPfd != null) {
            try {
                usbPfd.close();
            } catch (IOException e) {
                /* Deliberately dropping this descriptor; a failed close is not
                 * something the caller can act on. */
            }
            usbPfd = null;
        }
        if (usbServer != null) {
            try {
                usbServer.close();
            } catch (IOException e) {
                /* Same. */
            }
            usbServer = null;
        }
    }

    private void usbAttachNotice(Intent i) {
        if (i == null || !UsbManager.ACTION_USB_DEVICE_ATTACHED.equals(i.getAction()))
            return;
        UsbDevice d = (UsbDevice) i.getParcelableExtra(UsbManager.EXTRA_DEVICE);
        log("usb: " + (d != null ? usbId(d) : "a device")
                + " attached -- tick 'usb' in Settings and Boot\n");
    }
}
