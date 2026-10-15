package org.umarm.debian;

import android.app.ActionBar;
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
import android.graphics.Typeface;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbManager;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.os.PowerManager;
import android.system.Os;
import android.system.OsConstants;
import android.provider.Settings;
import android.text.InputType;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

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
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;

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
     * The guest image is not in the APK. It is 144 MB gzipped, and bundling it
     * made every app build 289 MB, made an image fix reach only a fresh install,
     * and made the app the unit of versioning for something it does not own. It
     * is published as a GitHub release asset instead, and this is where the app
     * looks for it.
     *
     * The release's *body* is the manifest -- a small JSON object with the md5
     * and the byte count -- so one request to the releases API says both what the
     * newest image is and whether the installed one is it. The releases list
     * comes back newest first, so the first rootfs-* entry is the latest.
     */
    private static final String RELEASES_API =
            "https://api.github.com/repos/Leonisaurov/linux-um-arm64/releases?per_page=10";
    private static final String IMAGE_TAG_PREFIX = "rootfs-";
    private static final String IMAGE_ASSET = "rootfs.ext4.gz";
    private static final String IMAGE_NAME = "rootfs.ext4";
    private static final String IMAGE_VERSION = "rootfs.version";
    private static final String IMAGE_SKIPPED = "skipped-image";

    /*
     * The guest's data disk: a second file, separate from the base image, that
     * the guest mounts at /data and bind-mounts /home, /var/lib/docker,
     * /var/lib/umarm and /root onto. Installing a new guest image replaces the
     * base only -- a different file -- so a rootfs fix arrives without touching
     * anything the user made. The file is created here as a sparse 2 GiB
     * allocation and formatted by the guest's init on first boot; the app only
     * ever replaces it on a restore.
     */
    private static final String DATA_NAME = "data.ext4";
    private static final long DATA_SIZE = 2L << 30;
    /*
     * Desired sizes, in bytes. Persisted because a guest-image update replaces
     * rootfs.ext4 with the release's size, so the app has to know to grow it
     * again; the guest does the filesystem side at boot. 0 for the base means
     * "whatever the release ships". Only growth is offered: shrinking an ext4
     * with data on it is a different operation with a different risk.
     */
    private static final String PREF_DATA_SIZE = "dataSizeBytes";
    private static final String PREF_BASE_SIZE = "baseSizeBytes";
    private static final String BACKUP_DIR = "backups";
    private static final String BACKUP_PREFIX = "data-";
    private static final String BACKUP_SUFFIX = ".ext4.gz";
    /* How many automatic/manual backups to keep before the oldest is dropped. */
    private static final int BACKUPS_KEPT = 3;

    /*
     * The app's own releases, tagged with the recipe digest build-apk.sh bakes
     * into the manifest. "Is there a newer build" is then a string comparison,
     * and nothing has to remember to bump a version for it to be noticed.
     */
    private static final String APP_TAG_PREFIX = "umarm-";
    private static final String APP_ASSET = "umarm.apk";
    private static final String APP_SKIPPED = "skipped-app";

    /*
     * Bumped when a small asset that does ship inside the APK changes. Its name
     * is fixed and it is unpacked once, so without this an update would keep the
     * first copy forever. The guest image is not one of these: it carries its own
     * version, the release tag.
     */
    private static final String ASSET_REVISION = "3";

    private TerminalView terminalView;
    private FrameLayout root;
    private View scrim;
    private View drawer;
    private boolean drawerOpen;
    private int drawerWidth;
    private TextView startStop;
    private TextView ctrlKey;
    private TextView altKey;
    private TextView handleView;
    /*
     * The drawer row for Settings, kept so the alert can mark it too. The
     * always-visible cue is the handle; this is the same state one tap deeper.
     */
    private TextView settingsItem;
    /* Drag state for the handle, and the timer that shrinks it when idle. */
    private float handleDownX, handleDownY;
    private int handleStartX, handleStartY;
    private boolean handleMoved;
    private static final long HANDLE_IDLE_MS = 4000;
    private final Runnable shrinkHandle = new Runnable() {
        @Override public void run() { shrinkHandleNow(); }
    };

    /* Extra-key state, read by the view for the soft keyboard. */
    private boolean mCtrl, mAlt, mShift, mFn;

    private int fontSizeSp = 12;
    /* "monospace", "sans", "serif", or "file:<name>" for a font the user loaded. */
    private String fontFamily = "monospace";

    /* Settings, persisted so a reboot of the guest does not lose them. */
    private EditText memField;
    private CheckBox seccompBox;
    private CheckBox netBox;
    private CheckBox usbBox;
    private CheckBox autobootBox;
    private CheckBox hideBarBox;
    private CheckBox keepAwakeBox;
    private CheckBox wakeLockBox;
    /* Whether the battery-optimization question has been asked this run. */
    private boolean batteryAsked;
    private Button fontButton;
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

        root = new FrameLayout(this);
        root.setBackgroundColor(0xFF0D0D0D);

        fontSizeSp = prefs.getInt("font", 12);
        fontFamily = prefs.getString("fontFamily", "monospace");
        terminalView = new TerminalView(this, null);
        terminalView.setTerminalViewClient(this);
        terminalView.setFocusable(true);
        terminalView.setFocusableInTouchMode(true);
        terminalView.setTextSize(fontSizeSp);
        root.addView(terminalView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        /* Tapping outside the drawer closes it, the way a menu should. It sits
         * over the terminal and under the drawer, so a tap on the panel is the
         * panel's and a tap anywhere else is this. */
        scrim = new View(this);
        scrim.setBackgroundColor(0x99000000);
        scrim.setClickable(true);
        scrim.setVisibility(View.GONE);
        scrim.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { closeDrawer(); }
        });
        root.addView(scrim, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        handleView = new TextView(this);
        handleView.setText("\u2261");
        handleView.setTextSize(22);
        handleView.setTextColor(0xFFE0E0E0);
        handleView.setGravity(Gravity.CENTER);
        handleView.setBackgroundResource(R.drawable.umarm_handle_bg);
        handleView.setClickable(true);
        handleView.setOnTouchListener(handleTouch);
        FrameLayout.LayoutParams handleParams = new FrameLayout.LayoutParams(dp(44), dp(44));
        handleParams.gravity = Gravity.TOP | Gravity.START;
        root.addView(handleView, handleParams);

        drawer = buildDrawer();
        drawerWidth = Math.min(dp(300),
                getResources().getDisplayMetrics().widthPixels - dp(56));
        FrameLayout.LayoutParams drawerParams =
                new FrameLayout.LayoutParams(drawerWidth, ViewGroup.LayoutParams.MATCH_PARENT);
        drawerParams.gravity = Gravity.TOP | Gravity.START;
        drawer.setTranslationX(-drawerWidth);
        root.addView(drawer, drawerParams);

        setContentView(root);

        loadSettings();
        paintModifiers();
        applyFont();
        applyChrome();
        paintBootState();

        /*
         * Where the handle goes is only known once the content has been laid
         * out, and the idle timer starts from there too: it shrinks a few
         * seconds after the app opens, not the moment it does.
         */
        root.post(new Runnable() {
            @Override public void run() {
                restoreHandlePosition();
                ui.postDelayed(shrinkHandle, HANDLE_IDLE_MS);
            }
        });

        log("umarm -- Linux/UML on aarch64, Termux terminal, inside an Android app\n");
        log("uid " + android.os.Process.myUid() + " libdir "
                + getApplicationInfo().nativeLibraryDir + "\n");
        log("recipe " + recipe() + "\n");

        usbAttachNotice(getIntent());
        checkUpdatesAsync(false);

        /*
         * Boot without a tap when the user asked for it. onCreate and not
         * onResume: onResume also fires after the font picker or a dialog, and a
         * guest that started once should not be restarted by coming back to the
         * app.
         */
        if (prefs.getBoolean("autoboot", false) && !isGuestRunning()) boot();

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
        /* "Stop" on the notification: the service asked us to end the guest. */
        if (UmarmService.ACTION_STOP.equals(i.getAction())) {
            stopGuest();
            return;
        }
        usbAttachNotice(i);
    }

    @Override
    protected void onResume() {
        super.onResume();
        /* The platform can put the bar back on its own; the preference wins. */
        applyChrome();
        if (terminalView != null && terminalView.mEmulator != null)
            terminalView.onScreenUpdated();
        /* Coming back from a dialog or the installer changes nothing the state
         * methods saw, so the alert is repainted here too. */
        paintBootState();
    }

    @Override
    protected void onDestroy() {
        if (isFinishing()) stopGuest();
        super.onDestroy();
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    /* ------------------------------------------------------------------
     * The drawer. A row of buttons across the top and a strip of keys across the
     * bottom put two bands of chrome on a phone screen to expose a dozen actions
     * a run mostly does not touch, and the terminal should have the screen. What
     * is left is a handle in one corner and this panel, closed by default.
     * ------------------------------------------------------------------ */

    private View buildDrawer() {
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundResource(R.drawable.umarm_drawer_bg);
        scroll.setFillViewport(true);

        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.VERTICAL);
        /* 58dp on top clears the handle, which stays where it is. */
        v.setPadding(dp(10), dp(58), dp(10), dp(24));
        scroll.addView(v);

        TextView title = new TextView(this);
        title.setText("umarm");
        title.setTextSize(24);
        title.setTextColor(0xFFF2F2F2);
        title.setPadding(dp(8), 0, 0, dp(2));
        v.addView(title);

        TextView sub = new TextView(this);
        sub.setText("Alpine + Docker on a real terminal");
        sub.setTextSize(12);
        sub.setTextColor(0xFF8A8A8A);
        sub.setPadding(dp(8), 0, 0, dp(10));
        v.addView(sub);

        startStop = drawerItem(v, "Boot", new View.OnClickListener() {
            @Override public void onClick(View w) {
                closeDrawer();
                if (isGuestRunning()) stopGuest(); else boot();
            }
        });

        drawerItem(v, "Keyboard", new View.OnClickListener() {
            @Override public void onClick(View w) { closeDrawer(); showKeyboard(); }
        });

        LinearLayout fontRow = new LinearLayout(this);
        fontRow.setOrientation(LinearLayout.HORIZONTAL);
        v.addView(fontRow, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        drawerItemInRow(fontRow, "Font \u2212", new View.OnClickListener() {
            @Override public void onClick(View w) {
                fontSizeSp = Math.max(6, fontSizeSp - 1);
                applyFont();
            }
        });
        drawerItemInRow(fontRow, "Font +", new View.OnClickListener() {
            @Override public void onClick(View w) {
                fontSizeSp = Math.min(32, fontSizeSp + 1);
                applyFont();
            }
        });

        drawerSection(v, "Updates");
        drawerItem(v, "Check for a guest image", new View.OnClickListener() {
            @Override public void onClick(View w) { closeDrawer(); checkUpdatesAsync(true); }
        });
        drawerItem(v, "Check for an app update", new View.OnClickListener() {
            @Override public void onClick(View w) { closeDrawer(); checkAppUpdateAsync(true); }
        });

        drawerSection(v, "Data");
        drawerItem(v, "Back up guest data", new View.OnClickListener() {
            @Override public void onClick(View w) { closeDrawer(); manualBackup(); }
        });
        drawerItem(v, "Restore guest data", new View.OnClickListener() {
            @Override public void onClick(View w) { closeDrawer(); chooseRestore(); }
        });
        drawerItem(v, "Export a backup\u2026", new View.OnClickListener() {
            @Override public void onClick(View w) { closeDrawer(); exportBackup(); }
        });
        drawerItem(v, "Import a backup\u2026", new View.OnClickListener() {
            @Override public void onClick(View w) { closeDrawer(); importBackup(); }
        });
        drawerItem(v, "Grow disks\u2026", new View.OnClickListener() {
            @Override public void onClick(View w) { closeDrawer(); showGrowDisks(); }
        });

        drawerSection(v, "Keys");
        v.addView(buildKeyGrid());

        drawerSection(v, "More");
        settingsItem = drawerItem(v, "Settings", new View.OnClickListener() {
            @Override public void onClick(View w) { closeDrawer(); showSettings(); }
        });

        return scroll;
    }

    private TextView newDrawerItem(String label, View.OnClickListener onClick) {
        TextView t = new TextView(this);
        t.setText(label);
        t.setTextSize(15);
        t.setTextColor(0xFFE8E8E8);
        t.setBackgroundResource(R.drawable.umarm_item_bg);
        t.setPadding(dp(12), dp(12), dp(12), dp(12));
        t.setClickable(true);
        t.setOnClickListener(onClick);
        return t;
    }

    private TextView drawerItem(LinearLayout parent, String label, View.OnClickListener onClick) {
        TextView t = newDrawerItem(label, onClick);
        parent.addView(t, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return t;
    }

    private TextView drawerItemInRow(LinearLayout row, String label,
            View.OnClickListener onClick) {
        TextView t = newDrawerItem(label, onClick);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        lp.setMargins(dp(2), 0, dp(2), 0);
        row.addView(t, lp);
        return t;
    }

    private void drawerSection(LinearLayout parent, String label) {
        TextView t = new TextView(this);
        t.setText(label.toUpperCase(Locale.US));
        t.setTextSize(11);
        t.setTextColor(0xFF7E7E7E);
        t.setPadding(dp(12), dp(16), dp(12), dp(6));
        parent.addView(t);
    }

    /*
     * The keys the extra strip used to hold. They are here instead of above the
     * keyboard: nothing is lost -- a latched CTRL still applies to the next
     * character from the soft keyboard -- and the terminal is not permanently
     * 40dp shorter. Tapping a key does not close the drawer, so several can be
     * sent in a row; the modifier keys latch and show it.
     */
    private View buildKeyGrid() {
        LinearLayout grid = new LinearLayout(this);
        grid.setOrientation(LinearLayout.VERTICAL);

        LinearLayout r1 = drawerRow(grid);
        ctrlKey = drawerKey(r1, "CTRL", new Runnable() {
            @Override public void run() { mCtrl = !mCtrl; paintModifiers(); }
        });
        altKey = drawerKey(r1, "ALT", new Runnable() {
            @Override public void run() { mAlt = !mAlt; paintModifiers(); }
        });
        drawerKey(r1, "SHIFT", new Runnable() {
            @Override public void run() { mShift = !mShift; paintModifiers(); }
        });
        drawerKey(r1, "FN", new Runnable() {
            @Override public void run() { mFn = !mFn; paintModifiers(); }
        });

        LinearLayout r2 = drawerRow(grid);
        drawerKey(r2, "ESC", new Runnable() {
            @Override public void run() { writeToSession("\u001b"); }
        });
        drawerKey(r2, "TAB", new Runnable() {
            @Override public void run() { writeToSession("\t"); }
        });
        drawerKey(r2, "^C", new Runnable() {
            @Override public void run() { writeToSession("\u0003"); }
        });
        drawerKey(r2, "^D", new Runnable() {
            @Override public void run() { writeToSession("\u0004"); }
        });

        LinearLayout r3 = drawerRow(grid);
        drawerKey(r3, "\u2191", new Runnable() {
            @Override public void run() { writeToSession("\u001b[A"); }
        });
        drawerKey(r3, "\u2193", new Runnable() {
            @Override public void run() { writeToSession("\u001b[B"); }
        });
        drawerKey(r3, "\u2190", new Runnable() {
            @Override public void run() { writeToSession("\u001b[D"); }
        });
        drawerKey(r3, "\u2192", new Runnable() {
            @Override public void run() { writeToSession("\u001b[C"); }
        });

        LinearLayout r4 = drawerRow(grid);
        drawerKey(r4, "/", new Runnable() {
            @Override public void run() { writeToSession("/"); }
        });
        drawerKey(r4, "-", new Runnable() {
            @Override public void run() { writeToSession("-"); }
        });
        drawerKey(r4, "|", new Runnable() {
            @Override public void run() { writeToSession("|"); }
        });
        drawerKey(r4, "~", new Runnable() {
            @Override public void run() { writeToSession("~"); }
        });

        LinearLayout r5 = drawerRow(grid);
        drawerKey(r5, "PASTE", new Runnable() {
            @Override public void run() { paste(); }
        });
        return grid;
    }

    private LinearLayout drawerRow(LinearLayout parent) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        parent.addView(row, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return row;
    }

    private TextView drawerKey(LinearLayout row, String label, final Runnable action) {
        TextView t = new TextView(this);
        t.setText(label);
        t.setTextSize(12);
        t.setTextColor(0xFFDCDCDC);
        t.setGravity(Gravity.CENTER);
        t.setBackgroundResource(R.drawable.umarm_key_bg);
        t.setPadding(0, dp(10), 0, dp(10));
        t.setClickable(true);
        t.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { action.run(); }
        });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        lp.setMargins(dp(3), dp(3), dp(3), dp(3));
        row.addView(t, lp);
        return t;
    }

    private void toggleDrawer() {
        if (drawerOpen) closeDrawer(); else openDrawer();
    }

    private void openDrawer() {
        drawerOpen = true;
        scrim.setVisibility(View.VISIBLE);
        drawer.animate().translationX(0).setDuration(180).start();
        /*
         * The IME would otherwise stay up over the panel, and the terminal under
         * it has no use for it while the drawer is open.
         */
        InputMethodManager imm =
                (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) imm.hideSoftInputFromWindow(terminalView.getWindowToken(), 0);
    }

    private void closeDrawer() {
        drawerOpen = false;
        scrim.setVisibility(View.GONE);
        drawer.animate().translationX(-drawerWidth).setDuration(180).start();
        terminalView.requestFocus();
    }

    /*
     * The handle moves. A tap opens the panel, a drag puts it anywhere the user
     * wants, and the place is remembered as a fraction of the screen so a
     * rotation or a different device cannot leave it off-screen. When it is left
     * alone it shrinks and fades, because a permanent 44dp square over a terminal
     * is the chrome this app is trying not to have.
     */
    private final View.OnTouchListener handleTouch = new View.OnTouchListener() {
        @Override public boolean onTouch(View v, MotionEvent e) {
            switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                handleDownX = e.getRawX();
                handleDownY = e.getRawY();
                handleStartX = Math.round(v.getX());
                handleStartY = Math.round(v.getY());
                handleMoved = false;
                wakeHandle();
                return true;
            case MotionEvent.ACTION_MOVE: {
                float dx = e.getRawX() - handleDownX;
                float dy = e.getRawY() - handleDownY;
                if (!handleMoved && Math.abs(dx) < dp(6) && Math.abs(dy) < dp(6))
                    return true;
                handleMoved = true;
                v.setX(clamp(handleStartX + dx, 0, root.getWidth() - v.getWidth()));
                v.setY(clamp(handleStartY + dy, 0, root.getHeight() - v.getHeight()));
                return true;
            }
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                if (handleMoved) saveHandlePosition(); else toggleDrawer();
                ui.removeCallbacks(shrinkHandle);
                ui.postDelayed(shrinkHandle, HANDLE_IDLE_MS);
                return true;
            }
            return false;
        }
    };

    private static float clamp(float v, float lo, float hi) {
        if (hi < lo) hi = lo;
        return v < lo ? lo : (v > hi ? hi : v);
    }

    /** Full size and opaque while it is in use. */
    private void wakeHandle() {
        ui.removeCallbacks(shrinkHandle);
        if (handleView == null) return;
        handleView.animate().cancel();
        handleView.setScaleX(1f);
        handleView.setScaleY(1f);
        handleView.setAlpha(1f);
    }

    private void shrinkHandleNow() {
        if (handleView == null) return;
        /* An alert must stay readable after the idle shrink, so it does not fade
         * as far as the ordinary handle does. */
        float a = isGuestRunning() ? 0.45f : 0.8f;
        handleView.animate().scaleX(0.62f).scaleY(0.62f).alpha(a)
                .setDuration(400).start();
    }

    private void saveHandlePosition() {
        if (handleView == null) return;
        float w = root.getWidth() - handleView.getWidth();
        float h = root.getHeight() - handleView.getHeight();
        prefs.edit()
                .putFloat("handleXf", w > 0 ? handleView.getX() / w : 0f)
                .putFloat("handleYf", h > 0 ? handleView.getY() / h : 0f)
                .apply();
    }

    private void restoreHandlePosition() {
        if (handleView == null || root.getWidth() == 0) return;
        float w = root.getWidth() - handleView.getWidth();
        float h = root.getHeight() - handleView.getHeight();
        float fx = prefs.getFloat("handleXf", -1f);
        float fy = prefs.getFloat("handleYf", -1f);
        if (fx < 0f || fy < 0f) {
            /* First run: where it always was, in the corner. */
            handleView.setX(dp(10));
            handleView.setY(dp(10));
            return;
        }
        handleView.setX(clamp(fx * w, 0, w));
        handleView.setY(clamp(fy * h, 0, h));
    }

    @Override
    public void onBackPressed() {
        if (drawerOpen) { closeDrawer(); return; }
        super.onBackPressed();
    }

    private void applyFont() {
        Typeface base = terminalTypeface();
        terminalView.setTypeface(base, Typeface.create(base, Typeface.ITALIC));
        terminalView.setTextSize(fontSizeSp);
        prefs.edit().putInt("font", fontSizeSp).putString("fontFamily", fontFamily).apply();
        if (fontButton != null) fontButton.setText("Font: " + fontFamilyLabel());
    }

    /*
     * The family the terminal is drawn in. The three system families are always
     * there; "file:" is a .ttf or .otf the user loaded, kept in the app's own
     * files directory because the terminal needs a real file and the picked URI
     * does not outlive the process. Anything unreadable falls back to monospace
     * rather than leaving the terminal with no font at all.
     */
    private Typeface terminalTypeface() {
        if ("sans".equals(fontFamily)) return Typeface.SANS_SERIF;
        if ("serif".equals(fontFamily)) return Typeface.SERIF;
        if (fontFamily != null && fontFamily.startsWith("file:")) {
            File f = new File(getFilesDir(), fontFamily.substring("file:".length()));
            if (f.isFile()) {
                try {
                    Typeface t = Typeface.createFromFile(f);
                    if (t != null) return t;
                } catch (RuntimeException e) {
                    log("font " + f + " did not load: " + e + "\n");
                }
            }
        }
        return Typeface.MONOSPACE;
    }

    private File customFontFile() {
        File f = new File(getFilesDir(), "terminal.ttf");
        return f.isFile() ? f : null;
    }

    private String fontFamilyLabel() {
        if ("sans".equals(fontFamily)) return "Sans-serif";
        if ("serif".equals(fontFamily)) return "Serif";
        if (fontFamily != null && fontFamily.startsWith("file:"))
            return prefs.getString("fontLabel", "custom");
        return "Monospace";
    }

    private void chooseFont() {
        final List<String> labels = new ArrayList<String>();
        final List<String> values = new ArrayList<String>();
        labels.add("Monospace");  values.add("monospace");
        labels.add("Sans-serif"); values.add("sans");
        labels.add("Serif");      values.add("serif");
        if (customFontFile() != null) {
            labels.add("Loaded: " + prefs.getString("fontLabel", "terminal.ttf"));
            values.add("file:" + customFontFile().getName());
        }
        labels.add("Load a font file (.ttf / .otf)\u2026");
        values.add("pick");

        new AlertDialog.Builder(this)
                .setTitle("Terminal font")
                .setItems(labels.toArray(new String[0]), new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface d, int which) {
                        String v = values.get(which);
                        if ("pick".equals(v)) { pickFontFile(); return; }
                        fontFamily = v;
                        applyFont();
                    }
                })
                .show();
    }

    /*
     * The document picker, not a path: an app has no useful view of the
     * filesystem, and the font has to be copied into the app's own directory
     * anyway so it survives the URI permission that came with the intent.
     */
    private static final int PICK_FONT = 41;

    private void pickFontFile() {
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("*/*");
        try {
            startActivityForResult(i, PICK_FONT);
        } catch (Exception e) {
            toast("no file picker here: " + e);
        }
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK || data == null || data.getData() == null) {
            if (request == EXPORT_BACKUP || request == IMPORT_BACKUP)
                toast("cancelled");
            return;
        }
        Uri uri = data.getData();
        if (request == PICK_FONT) loadFont(uri);
        else if (request == EXPORT_BACKUP) exportBackupTo(uri);
        else if (request == IMPORT_BACKUP) importBackupFrom(uri);
    }

    private void loadFont(Uri uri) {
        File out = new File(getFilesDir(), "terminal.ttf");
        try {
            InputStream in = getContentResolver().openInputStream(uri);
            if (in == null) throw new IOException("cannot open " + uri);
            FileOutputStream fos = new FileOutputStream(out);
            byte[] buf = new byte[1 << 16];
            long total = 0;
            int n;
            while ((n = in.read(buf)) > 0) { fos.write(buf, 0, n); total += n; }
            fos.close();
            in.close();
            if (Typeface.createFromFile(out) == null) throw new IOException("not a font");
            String name = displayName(uri);
            fontFamily = "file:" + out.getName();
            prefs.edit().putString("fontLabel", name).apply();
            applyFont();
            toast("font loaded: " + name + " (" + (total / 1024) + " KB)");
        } catch (Exception e) {
            out.delete();
            toast("could not load that font: " + e);
        }
    }

    /** A readable name for a picked document, with a fallback for providers that
     *  do not offer one. */
    private String displayName(Uri uri) {
        try {
            android.database.Cursor c = getContentResolver().query(uri, null, null, null, null);
            if (c != null) {
                try {
                    int i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME);
                    if (i >= 0 && c.moveToFirst()) {
                        String s = c.getString(i);
                        if (s != null && s.length() > 0) return s;
                    }
                } finally {
                    c.close();
                }
            }
        } catch (Exception e) {
            /* fall through to the path segment */
        }
        String s = uri.getLastPathSegment();
        return s == null ? "font" : s;
    }

    /*
     * The top bar is the platform's ActionBar, so it can be hidden and shown
     * again at runtime. A theme without one would be simpler, but it would turn
     * the choice into a build-time decision instead of an option.
     */
    private void applyChrome() {
        ActionBar bar = getActionBar();
        if (bar == null) return;
        if (prefs.getBoolean("hideBar", false)) bar.hide(); else bar.show();
    }

    /*
     * Keep the screen on only while a guest is actually running: an idle app
     * showing an empty terminal has no reason to hold the display awake.
     */
    private void applyKeepAwake() {
        if (prefs.getBoolean("keepAwake", false) && isGuestRunning())
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else
            getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    /*
     * The foreground service is what keeps the guest alive off-screen; see
     * UmarmService. Started only while a guest is actually running, and stopped
     * with it, so the notification never outlives the thing it describes.
     */
    private void startGuestService() {
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                   != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(
                    new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 42);
        }
        Intent i = new Intent(this, UmarmService.class);
        i.setAction(UmarmService.ACTION_START);
        boolean wake = prefs.getBoolean("wakeLock", false);
        i.putExtra(UmarmService.EXTRA_WAKELOCK, wake);
        startForegroundService(i);
        /* A wakelock without the exemption is the wakelock Android ignores. */
        if (wake) askBatteryExemption(false);
    }

    private void stopGuestService() {
        stopService(new Intent(this, UmarmService.class));
    }

    /*
     * The wakelock keeps the CPU awake; battery optimization is the other half,
     * and it is the half that freezes the whole app. Android has one dialog for
     * this, and the app can only ask for it -- Settings
     * .ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, with this package in the
     * data URI. Some builds do not have the direct dialog, so the list is the
     * fallback rather than an error.
     */
    private void askBatteryExemption(boolean manual) {
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (pm == null || pm.isIgnoringBatteryOptimizations(getPackageName())) {
            if (manual) toast("umarm is already exempt from battery optimization");
            return;
        }
        if (batteryAsked && !manual) return;
        batteryAsked = true;
        new AlertDialog.Builder(this)
                .setTitle("Battery optimization")
                .setMessage("Android can still freeze the guest to save power, even with a "
                        + "wakelock. Exclude umarm from battery optimization?")
                .setPositiveButton("Open settings", new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface d, int which) {
                        requestBatteryExemption();
                    }
                })
                .setNegativeButton("Not now", null)
                .show();
    }

    private void requestBatteryExemption() {
        try {
            Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            i.setData(Uri.parse("package:" + getPackageName()));
            startActivity(i);
        } catch (Exception e) {
            try {
                startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
            } catch (Exception e2) {
                toast("no battery optimization settings on this device: " + e2);
            }
        }
    }

    private void paintModifiers() {
        ctrlKey.setSelected(mCtrl);
        altKey.setSelected(mAlt);
        /* SHIFT and FN have no handle of their own; the view reads their state
         * through readShiftKey()/readFnKey(). */
    }

    /*
     * Whether the guest is up, as something the screen says without being asked.
     * Not running means the handle is the only place to say it -- the drawer is
     * closed -- so it gets a red ring, and the Settings row behind it gets the
     * same colour for the moment the drawer is open. Both are switched off the
     * moment a session exists: "booting" and "booted" are close enough that a
     * second state would only flicker.
     */
    private void paintBootState() {
        boolean running = isGuestRunning();
        if (handleView != null) {
            handleView.setBackgroundResource(running
                    ? R.drawable.umarm_handle_bg
                    : R.drawable.umarm_handle_alert_bg);
            handleView.setContentDescription(running
                    ? "Open the umarm menu"
                    : "The guest is not booted. Open the menu to start it.");
        }
        if (settingsItem != null)
            settingsItem.setTextColor(running ? 0xFFE8E8E8 : 0xFFFF5252);
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

        autobootBox = new CheckBox(this);
        autobootBox.setText("Boot when the app opens");
        autobootBox.setChecked(prefs.getBoolean("autoboot", false));

        hideBarBox = new CheckBox(this);
        hideBarBox.setText("Hide the top bar");
        hideBarBox.setChecked(prefs.getBoolean("hideBar", false));

        keepAwakeBox = new CheckBox(this);
        keepAwakeBox.setText("Keep the screen on while the guest runs");
        keepAwakeBox.setChecked(prefs.getBoolean("keepAwake", false));

        wakeLockBox = new CheckBox(this);
        wakeLockBox.setText("Wake lock (keep the CPU on with the screen off)");
        wakeLockBox.setChecked(prefs.getBoolean("wakeLock", false));
        /* After setChecked, so restoring the preference does not ask again. */
        wakeLockBox.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener() {
            @Override public void onCheckedChanged(CompoundButton b, boolean checked) {
                if (checked) askBatteryExemption(false);
            }
        });
    }

    private void showSettings() {
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.VERTICAL);
        v.setPadding(dp(20), dp(4), dp(20), dp(4));

        drawerSection(v, "Appearance");
        v.addView(hideBarBox);
        v.addView(buildFontRow());

        drawerSection(v, "Startup");
        v.addView(autobootBox);
        v.addView(keepAwakeBox);
        v.addView(wakeLockBox);

        Button battery = new Button(this);
        battery.setText("Battery optimization\u2026");
        battery.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View w) { askBatteryExemption(true); }
        });
        v.addView(battery);

        drawerSection(v, "Guest");
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

        /* The dialog can be taller than a phone screen, so it scrolls. The update
         * entries live in the drawer; this dialog is only how the app and the
         * guest are configured. */
        ScrollView scroll = new ScrollView(this);
        scroll.addView(v);

        new AlertDialog.Builder(this)
                .setTitle("umarm settings")
                .setView(scroll)
                .setPositiveButton("Save", new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface d, int which) {
                        prefs.edit()
                                .putString("mem", memField.getText().toString())
                                .putBoolean("seccomp", seccompBox.isChecked())
                                .putBoolean("net", netBox.isChecked())
                                .putBoolean("usb", usbBox.isChecked())
                                .putBoolean("autoboot", autobootBox.isChecked())
                                .putBoolean("hideBar", hideBarBox.isChecked())
                                .putBoolean("keepAwake", keepAwakeBox.isChecked())
                                .putBoolean("wakeLock", wakeLockBox.isChecked())
                                .apply();
                        applyChrome();
                        applyKeepAwake();
                        /* The wakelock lives in the service, so a change to it
                         * only takes effect if the service is told again. */
                        if (isGuestRunning()) startGuestService();
                    }
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    /*
     * Growing is the app's half of one operation: it makes the file longer, and
     * the guest's next boot makes the filesystem fill it. The dialog says the
     * sizes in GiB and refuses to pretend shrinking is available. The free-space
     * line is the honest number for a sparse file: a bigger file allocates
     * nothing until it is written, so free space is a warning, not a limit.
     */
    private void showGrowDisks() {
        if (isGuestRunning()) { toast("stop the guest first"); return; }

        final File data = new File(getFilesDir(), DATA_NAME);
        final File base = new File(getFilesDir(), IMAGE_NAME);
        long dataGiB = Math.max(1, desiredDataSize() >> 30);
        long baseGiB = desiredBaseSize() > 0
                ? desiredBaseSize() >> 30
                : (base.exists() ? base.length() >> 30 : 1);

        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.VERTICAL);
        v.setPadding(dp(20), dp(4), dp(20), dp(4));

        drawerSection(v, "Data disk (home, docker)");
        final EditText dataField = new EditText(this);
        dataField.setInputType(InputType.TYPE_CLASS_NUMBER);
        dataField.setText(String.valueOf(dataGiB));
        v.addView(dataField);

        drawerSection(v, "Base image (Alpine)");
        final EditText baseField = new EditText(this);
        baseField.setInputType(InputType.TYPE_CLASS_NUMBER);
        baseField.setText(String.valueOf(baseGiB));
        v.addView(baseField);

        TextView note = new TextView(this);
        note.setText("Sizes in GiB. Disks only ever grow. The guest grows the "
                + "filesystem on its next boot.\n\nNow: data "
                + (data.length() >> 20) + " MB, base " + (base.length() >> 20)
                + " MB. Free: " + (getFilesDir().getUsableSpace() >> 20) + " MB.");
        v.addView(note);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(v);

        new AlertDialog.Builder(this)
                .setTitle("Grow disks")
                .setView(scroll)
                .setPositiveButton("Grow", new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface d, int which) {
                        long gb = parseGiB(dataField.getText().toString());
                        long bb = parseGiB(baseField.getText().toString());
                        prefs.edit()
                                .putLong(PREF_DATA_SIZE, gb << 30)
                                .putLong(PREF_BASE_SIZE, bb << 30)
                                .apply();
                        boolean ok = applyDesiredSizes();
                        toast(ok ? "grown -- reboot the guest to resize the filesystem"
                                 : "could not grow; see the log");
                    }
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private static long parseGiB(String s) {
        try { return Math.max(0, Long.parseLong(s.trim())); }
        catch (NumberFormatException e) { return 0; }
    }

    /*
     * Font size and family in one place: the size on a slider, the family behind
     * a chooser, both applied as they change so the terminal shows the result
     * instead of describing it.
     */
    private View buildFontRow() {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.VERTICAL);

        final TextView value = new TextView(this);
        value.setText("Font size " + fontSizeSp + " sp");
        row.addView(value);

        SeekBar size = new SeekBar(this);
        size.setMax(32 - 6);
        size.setProgress(fontSizeSp - 6);
        size.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar s, int p, boolean fromUser) {
                if (!fromUser) return;
                fontSizeSp = 6 + p;
                value.setText("Font size " + fontSizeSp + " sp");
                applyFont();
            }
            @Override public void onStartTrackingTouch(SeekBar s) { }
            @Override public void onStopTrackingTouch(SeekBar s) { }
        });
        row.addView(size);

        fontButton = new Button(this);
        fontButton.setText("Font: " + fontFamilyLabel());
        fontButton.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View w) { chooseFont(); }
        });
        row.addView(fontButton);
        return row;
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

        File rootfs = guestImage();
        File initrd = null;
        if (rootfs == null) {
            /*
             * No image yet: the download has not been accepted, or has not
             * finished. The initramfs still ships and is a real shell, so the
             * app boots rather than explaining that it cannot.
             */
            try {
                initrd = unpackAsset("initramfs.cpio.gz", "initramfs.cpio.gz");
            } catch (IOException e) {
                fail("ERROR: no guest image is installed and the APK has no initramfs: " + e);
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
            /*
             * The data disk goes on as ubd1. It is a different file from the
             * base image, so a guest-image update cannot reach it; the guest's
             * init formats it on the first boot that has one and mounts the
             * user's directories from it. Missing or uncreatable is not fatal:
             * the guest then keeps its data in the base image, as before.
             */
            File data = ensureGuestData();
            if (data != null)
                args.add("ubd1=" + data.getAbsolutePath());
            else
                log("no data disk: /home and docker will live on the base image\n");
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
            applyKeepAwake();
            startGuestService();
            paintBootState();
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
        applyKeepAwake();
        stopGuestService();
        paintBootState();
    }

    private void fail(String s) {
        log(s + "\n");
        toast(s);
        startStop.setText("Boot");
        applyKeepAwake();
        paintBootState();
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
        applyKeepAwake();
        stopGuestService();
        paintBootState();
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
            if (fontSizeSp != old) applyFont();
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
     *
     * The revision is compared first: the name is fixed, so an APK that ships a
     * new copy of a small asset would otherwise keep whatever it unpacked the
     * first time. The guest image is not one of these; it has a version of its
     * own, the release tag.
     */
    private File unpackAsset(String asset, String outName) throws IOException {
        File out = new File(getFilesDir(), outName);
        File rev = new File(getFilesDir(), outName + ".revision");
        if (out.exists() && out.length() > 0) {
            if (ASSET_REVISION.equals(firstLine(rev)))
                return out;
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

        FileOutputStream r = new FileOutputStream(rev);
        r.write((ASSET_REVISION + "\n").getBytes("UTF-8"));
        r.close();
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

    /* ------------------------------------------------------------------
     * The guest image, as a release asset
     * ------------------------------------------------------------------ */

    /** The installed image, or null when there is none yet. */
    private File guestImage() {
        File f = new File(getFilesDir(), IMAGE_NAME);
        return (f.exists() && f.length() > 0) ? f : null;
    }

    /** The release tag the installed image came from, or "" if unknown. */
    private String installedImageVersion() {
        return firstLine(new File(getFilesDir(), IMAGE_VERSION));
    }

    private void setInstalledImageVersion(String tag) throws IOException {
        FileOutputStream f = new FileOutputStream(new File(getFilesDir(), IMAGE_VERSION));
        f.write((tag + "\n").getBytes("UTF-8"));
        f.close();
    }

    /* ------------------------------------------------------------------
     * The data disk, and its backups
     * ------------------------------------------------------------------ */

    /** The data disk, or null when there is none yet. */
    private File guestData() {
        File f = new File(getFilesDir(), DATA_NAME);
        return (f.exists() && f.length() > 0) ? f : null;
    }

    private long desiredDataSize() {
        return Math.max(DATA_SIZE, prefs.getLong(PREF_DATA_SIZE, DATA_SIZE));
    }

    private long desiredBaseSize() {
        return prefs.getLong(PREF_BASE_SIZE, 0L);
    }

    /**
     * Grow a sparse file to at least `target` bytes. A larger sparse file costs
     * no space until it is written, so this is only refused when the file
     * cannot be extended at all. Never shrinks: an ext4 shrunk from this side
     * would be a filesystem with blocks past its end.
     */
    private boolean growFile(File f, long target) {
        if (f == null || !f.exists() || target <= f.length()) return false;
        RandomAccessFile raf = null;
        try {
            raf = new RandomAccessFile(f, "rw");
            raf.setLength(target);
            log("grew " + f.getName() + " to " + (target >> 30) + " GiB\n");
            return true;
        } catch (Exception e) {
            log("cannot grow " + f + ": " + e + "\n");
            return false;
        } finally {
            if (raf != null) try { raf.close(); } catch (IOException e) { }
        }
    }

    /** Apply both desired sizes; false when either failed. */
    private boolean applyDesiredSizes() {
        boolean ok = true;
        if (guestData() != null) ok &= growFile(guestData(), desiredDataSize());
        File base = guestImage();
        if (base != null && desiredBaseSize() > 0)
            ok &= growFile(base, desiredBaseSize());
        return ok;
    }

    /**
     * The data disk, created as a sparse file the first time. The guest's init
     * formats it (ext4) on the boot that follows, because nothing on this side
     * can, and the block layer needs a file that exists. A failure is not
     * fatal: the guest boots with its data in the base image, exactly as it did
     * before the split.
     */
    private File ensureGuestData() {
        File f = new File(getFilesDir(), DATA_NAME);
        if (f.exists() && f.length() > 0)
            return f;
        try {
            RandomAccessFile raf = new RandomAccessFile(f, "rw");
            try {
                raf.setLength(desiredDataSize());
            } finally {
                raf.close();
            }
            log("created the data disk " + DATA_NAME + " (" + (desiredDataSize() >> 30)
                    + " GiB, sparse; the guest formats it on the next boot)\n");
            return f;
        } catch (Exception e) {
            log("cannot create the data disk: " + e + "\n");
            f.delete();
            return null;
        }
    }

    /**
     * Where backups are written: the app's external files directory when there
     * is one, so a backup can be pulled off the phone over USB, and the private
     * directory otherwise. Created on demand.
     */
    private File backupsDir() {
        File base = getExternalFilesDir(null);
        if (base == null) base = getFilesDir();
        File d = new File(base, BACKUP_DIR);
        d.mkdirs();
        return d;
    }

    private static String stamp() {
        return new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new Date());
    }

    /** Backups, newest first. */
    private List<File> listBackups() {
        File[] all = backupsDir().listFiles();
        List<File> out = new ArrayList<File>();
        for (int i = 0; all != null && i < all.length; i++) {
            String n = all[i].getName();
            if (n.startsWith(BACKUP_PREFIX) && n.endsWith(BACKUP_SUFFIX))
                out.add(all[i]);
        }
        Collections.sort(out, new Comparator<File>() {
            @Override public int compare(File a, File b) {
                return b.getName().compareTo(a.getName());
            }
        });
        return out;
    }

    /** Drop the oldest backups, so a series of updates cannot fill the disk. */
    private void pruneBackups() {
        List<File> all = listBackups();
        for (int i = BACKUPS_KEPT; i < all.size(); i++)
            all.get(i).delete();
    }

    private void manualBackup() {
        if (guestData() == null) { toast("there is no data disk yet -- boot once"); return; }
        if (isGuestRunning()) { toast("stop the guest first"); return; }
        final Progress p = progressDialog("Backing up guest data");
        new Thread(new Runnable() {
            @Override public void run() { runBackup(p); }
        }, "umarm-backup").start();
    }

    private void runBackup(Progress p) {
        String ok = null, err = null;
        try {
            File data = guestData();
            if (data == null) throw new IOException("there is no data disk");
            File out = new File(backupsDir(), BACKUP_PREFIX + stamp() + BACKUP_SUFFIX);
            gzipFile(data, out, p);
            pruneBackups();
            ok = "backed up to " + out.getName() + " (" + (out.length() >> 20) + " MB)";
            log("backup: " + ok + "\n");
        } catch (Exception e) {
            err = e.toString();
            log("backup failed: " + err + "\n");
        }
        finishOp(p, ok, err);
    }

    private void chooseRestore() {
        if (isGuestRunning()) { toast("stop the guest first"); return; }
        final List<File> backups = listBackups();
        if (backups.isEmpty()) { toast("there are no backups yet"); return; }
        final String[] names = new String[backups.size()];
        for (int i = 0; i < backups.size(); i++)
            names[i] = backups.get(i).getName() + "   (" + (backups.get(i).length() >> 20) + " MB)";
        new AlertDialog.Builder(this)
                .setTitle("Restore guest data")
                .setItems(names, new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface d, int which) {
                        confirmRestore(backups.get(which));
                    }
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void confirmRestore(final File backup) {
        new AlertDialog.Builder(this)
                .setTitle("Restore " + backup.getName())
                .setMessage("Everything on the current data disk is replaced by this "
                        + "backup. The guest image itself is not touched.")
                .setPositiveButton("Restore", new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface d, int which) { startRestore(backup); }
                })
                .setNegativeButton("Cancel", null)
                .show();
    }

    private void startRestore(final File backup) {
        final Progress p = progressDialog("Restoring guest data");
        new Thread(new Runnable() {
            @Override public void run() { runRestore(backup, p); }
        }, "umarm-restore").start();
    }

    private void runRestore(File backup, Progress p) {
        String ok = null, err = null;
        try {
            File out = new File(getFilesDir(), DATA_NAME);
            File neu = new File(getFilesDir(), DATA_NAME + ".new");
            gunzipFile(backup, neu, p);
            if (out.exists() && !out.delete())
                throw new IOException("cannot replace " + out);
            if (!neu.renameTo(out))
                throw new IOException("cannot rename " + neu);
            ok = "restored the data disk from " + backup.getName();
            log("restored the data disk from " + backup.getName() + "\n");
        } catch (Exception e) {
            err = e.toString();
            log("restore failed: " + err + "\n");
        }
        finishOp(p, ok, err);
    }

    /*
     * Export and import go through the document picker rather than the backup
     * directory: a backup that lives in the app's own storage is gone when the
     * app is uninstalled, which is one of the things a backup is for. The large
     * copy runs on a thread -- a 2 GiB image on the main thread is an ANR -- so
     * the picker's result only starts it.
     */
    private static final int EXPORT_BACKUP = 42;
    private static final int IMPORT_BACKUP = 43;

    private void exportBackup() {
        if (guestData() == null) { toast("there is no data disk yet -- boot once"); return; }
        if (isGuestRunning()) { toast("stop the guest first"); return; }
        Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("application/gzip");
        i.putExtra(Intent.EXTRA_TITLE, BACKUP_PREFIX + stamp() + BACKUP_SUFFIX);
        try {
            startActivityForResult(i, EXPORT_BACKUP);
        } catch (Exception e) {
            toast("no file picker here: " + e);
        }
    }

    private void importBackup() {
        if (isGuestRunning()) { toast("stop the guest first"); return; }
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType("*/*");
        try {
            startActivityForResult(i, IMPORT_BACKUP);
        } catch (Exception e) {
            toast("no file picker here: " + e);
        }
    }

    private void exportBackupTo(final Uri uri) {
        final Progress p = progressDialog("Exporting guest data");
        new Thread(new Runnable() {
            @Override public void run() { runExport(uri, p); }
        }, "umarm-export").start();
    }

    private void runExport(Uri uri, Progress p) {
        String ok = null, err = null;
        try {
            File data = guestData();
            if (data == null) throw new IOException("there is no data disk");
            OutputStream os = getContentResolver().openOutputStream(uri);
            if (os == null) throw new IOException("cannot open " + uri);
            gzipTo(data, os, p);
            ok = "exported the data disk";
            log("exported the data disk to " + uri + "\n");
        } catch (Exception e) {
            err = e.toString();
            log("export failed: " + err + "\n");
        }
        finishOp(p, ok, err);
    }

    private void importBackupFrom(final Uri uri) {
        final Progress p = progressDialog("Importing guest data");
        new Thread(new Runnable() {
            @Override public void run() { runImport(uri, p); }
        }, "umarm-import").start();
    }

    private void runImport(Uri uri, Progress p) {
        String ok = null, err = null;
        try {
            InputStream in = getContentResolver().openInputStream(uri);
            if (in == null) throw new IOException("cannot open " + uri);
            File out = new File(getFilesDir(), DATA_NAME);
            File neu = new File(getFilesDir(), DATA_NAME + ".new");
            try {
                gunzipFrom(in, neu, p);
            } finally {
                in.close();
            }
            if (out.exists() && !out.delete())
                throw new IOException("cannot replace " + out);
            if (!neu.renameTo(out))
                throw new IOException("cannot rename " + neu);
            ok = "imported the data disk -- boot to use it";
            log("imported the data disk from " + uri + "\n");
        } catch (Exception e) {
            err = e.toString();
            log("import failed: " + err + "\n");
        }
        finishOp(p, ok, err);
    }

    /**
     * Copy the data disk aside before a reinstall. The update cannot reach the
     * data disk -- it is a different file -- so this is a second line of defence
     * and a failure here does not stop the reinstall. Returns the backup's name,
     * or null when there was nothing to back up or it failed.
     */
    private String backupBeforeUpdate(Release rel, Progress p) {
        File data = guestData();
        if (data == null) return null;
        try {
            File out = new File(backupsDir(),
                    BACKUP_PREFIX + "before-" + rel.version + BACKUP_SUFFIX);
            if (out.exists()) out.delete();
            progress(p, "backing up first", 0, 0);
            gzipFile(data, out, p);
            pruneBackups();
            log("backed up the data disk to " + out.getName()
                    + " before installing " + rel.tag + "\n");
            return out.getName();
        } catch (Exception e) {
            log("backup before the update failed (continuing): " + e + "\n");
            return null;
        }
    }

    private void gzipFile(File in, File out, Progress p) throws IOException {
        OutputStream out2 = new FileOutputStream(out);
        try {
            gzipTo(in, out2, p);
        } finally {
            out2.close();
        }
    }

    /**
     * Gzip a file onto an already-open stream. The stream is wrapped and the
     * wrapper closed, so the gzip trailer is written and the underlying stream
     * is flushed and closed. That is what the export path needs: writing the
     * bytes raw would put an ext4 image under a .gz name, and skipping the
     * close would leave the archive without its trailer.
     */
    private void gzipTo(File in, OutputStream out, Progress p) throws IOException {
        InputStream is = new FileInputStream(in);
        try {
            GZIPOutputStream gz = new GZIPOutputStream(out, 1 << 16);
            try {
                gzipBytes(is, gz, in.length(), p);
            } finally {
                gz.close();
            }
        } finally {
            is.close();
        }
    }

    private void gzipBytes(InputStream is, OutputStream os, long total, Progress p) throws IOException {
        progress(p, "compressing", 0, total);
        byte[] buf = new byte[1 << 16];
        long done = 0, last = 0;
        int n;
        while ((n = is.read(buf)) > 0) {
            os.write(buf, 0, n);
            done += n;
            if (done - last >= (16L << 20)) {
                last = done;
                progress(p, "compressing", done, total);
            }
        }
        progress(p, "compressing", done, total);
    }

    private void gunzipFile(File in, File out, Progress p) throws IOException {
        InputStream is = new GZIPInputStream(new FileInputStream(in), 1 << 16);
        try {
            OutputStream os = new FileOutputStream(out);
            try {
                gunzipBytes(is, os, gzipIsize(in), p);
            } finally {
                os.close();
            }
        } finally {
            is.close();
        }
    }

    /**
     * Gunzip an already-open stream onto a file. The stream is wrapped, so the
     * compressed bytes are decompressed rather than copied -- and the wrapper
     * is closed, which closes the caller's stream too (the import path hands in
     * a document-provider stream and nothing else closes it).
     */
    private void gunzipFrom(InputStream in, File out, Progress p) throws IOException {
        GZIPInputStream gz = new GZIPInputStream(in, 1 << 16);
        try {
            OutputStream os = new FileOutputStream(out);
            try {
                gunzipBytes(gz, os, 0, p);
            } finally {
                os.close();
            }
        } finally {
            gz.close();
        }
    }

    private void gunzipBytes(InputStream is, OutputStream os, long raw, Progress p) throws IOException {
        progress(p, "unpacking", 0, raw);
        byte[] buf = new byte[1 << 16];
        long done = 0, last = 0;
        int n;
        while ((n = is.read(buf)) > 0) {
            os.write(buf, 0, n);
            done += n;
            if (done - last >= (8L << 20)) {
                last = done;
                progress(p, "unpacking", done, raw);
            }
        }
        progress(p, "unpacking", done, raw);
    }

    /** One published release: which one it is, what it should hash to, where. */
    private static final class Release {
        String tag;
        String version;          /* the tag with its prefix stripped */
        String published = "";   /* published_at, or created_at if there is none */
        String md5 = "";
        long size;
        String url = "";
    }

    /*
     * Asked once per Activity start and from the drawer, always off the main
     * thread: it is a network call, and its only product is deciding whether to
     * show a dialog.
     */
    private void checkUpdatesAsync(final boolean manual) {
        new Thread(new Runnable() {
            @Override public void run() { checkUpdates(manual); }
        }, "umarm-update-check").start();
    }

    private void checkAppUpdateAsync(final boolean manual) {
        new Thread(new Runnable() {
            @Override public void run() { checkAppUpdate(manual); }
        }, "umarm-app-check").start();
    }

    /**
     * The app first, when there is an image to run with, and the image only if
     * the app had nothing to say. Two dialogs would otherwise land on top of each
     * other, and an update to the app is the one worth answering first -- the
     * image check runs again on the next start either way.
     */
    private void checkUpdates(boolean manual) {
        boolean prompted = false;
        if (guestImage() != null)
            prompted = checkAppUpdate(manual);
        if (!prompted)
            checkImage(manual);
    }

    /**
     * Compare the installed image with the newest published one and offer the
     * download when they differ. manual is the drawer entry, which reports the
     * outcome rather than staying quiet when there is nothing to do.
     */
    private void checkImage(final boolean manual) {
        final Release rel;
        try {
            rel = fetchLatestRelease(IMAGE_TAG_PREFIX, IMAGE_ASSET);
        } catch (Exception e) {
            log("image check failed: " + e + "\n");
            if (manual) post("could not check for a new image: " + e);
            return;
        }
        if (rel == null) {
            if (manual) post("no guest image is published yet");
            return;
        }

        final boolean present = guestImage() != null;
        if (present && rel.tag.equals(installedImageVersion())) {
            if (manual) post("the guest image is up to date (" + rel.tag + ")");
            return;
        }
        /*
         * "Keep" means keep this one: remembered for that version, so the
         * question is asked once per image and the drawer can ask again.
         */
        if (!manual && rel.tag.equals(prefs.getString(IMAGE_SKIPPED, "")))
            return;
        ui.post(new Runnable() {
            @Override public void run() { askImage(rel, present); }
        });
    }

    /**
     * Is there a newer build of the app itself? The identity is the recipe baked
     * into this APK's manifest by build-apk.sh -- a digest of everything that
     * went into it -- so the answer is right without anything being bumped by
     * hand. Returns whether a dialog was posted, so the caller can hold the image
     * question back.
     */
    private boolean checkAppUpdate(final boolean manual) {
        final String mine = recipe();
        final Release rel;
        try {
            rel = fetchLatestRelease(APP_TAG_PREFIX, APP_ASSET);
        } catch (Exception e) {
            log("app update check failed: " + e + "\n");
            if (manual) post("could not check for a new app version: " + e);
            return false;
        }
        if (rel == null) {
            if (manual) post("no app release is published yet");
            return false;
        }
        if (rel.version.equals(mine)) {
            if (manual) post("the app is up to date (" + mine + ")");
            return false;
        }
        if (!manual && rel.version.equals(prefs.getString(APP_SKIPPED, "")))
            return false;
        /*
         * Whether the APK already in the cache is *this* release is decided
         * here and not in the dialog: it reads and hashes the file, and this
         * runs on the check's own thread while the dialog runs on the UI one.
         */
        final boolean have = cachedAppUpdate(rel);
        ui.post(new Runnable() {
            @Override public void run() { askAppUpdate(rel, have); }
        });
        return true;
    }

    /**
     * The newest release whose tag starts with tagPrefix and which carries asset.
     *
     * "Newest" is computed from published_at rather than taken from the order the
     * API returns, because that order is not the documented one. The docs say
     * "sorted by created_at, descending" and what GitHub actually returned was
     * umarm-ea5ba1424a6d (13:50) and umarm-a83c8b925c82 (13:29) *above*
     * umarm-7c974e3214bc (14:07) -- tag-name order. Trusting it would have offered
     * an installed app a downgrade, and gone on offering it.
     *
     * The timestamps are ISO 8601 in UTC with a fixed width, so comparing them as
     * strings is comparing them as dates.
     */
    private Release fetchLatestRelease(String tagPrefix, String asset)
            throws IOException, JSONException {
        JSONArray releases = new JSONArray(httpGet(RELEASES_API, 20000));
        Release best = null;
        for (int i = 0; i < releases.length(); i++) {
            JSONObject r = releases.getJSONObject(i);
            String tag = r.optString("tag_name", "");
            if (!tag.startsWith(tagPrefix))
                continue;

            Release out = new Release();
            out.tag = tag;
            out.version = tag.substring(tagPrefix.length());
            out.published = r.optString("published_at", "");
            if (out.published.length() == 0)
                out.published = r.optString("created_at", "");
            try {
                JSONObject m = new JSONObject(r.optString("body", ""));
                out.md5 = m.optString("md5", "");
                out.size = m.optLong("size", 0);
            } catch (JSONException e) {
                /* Not the manifest: the download is still offered, the hash check
                 * is skipped, and the size comes from the HTTP response. */
                log("release " + tag + " has no manifest in its body\n");
            }
            JSONArray assets = r.optJSONArray("assets");
            for (int j = 0; assets != null && j < assets.length(); j++) {
                JSONObject a = assets.getJSONObject(j);
                if (asset.equals(a.optString("name", ""))) {
                    out.url = a.optString("browser_download_url", "");
                    if (out.size <= 0) out.size = a.optLong("size", 0);
                }
            }
            if (out.url.length() > 0
                    && (best == null || out.published.compareTo(best.published) > 0))
                best = out;
        }
        return best;
    }

    private void askImage(final Release rel, final boolean present) {
        long mb = rel.size > 0 ? rel.size >> 20 : 0;
        StringBuilder m = new StringBuilder();
        if (present) {
            m.append("There is a newer guest image (").append(rel.tag);
            if (mb > 0) m.append(", ").append(mb).append(" MB");
            m.append(").\n\nIt replaces the base system only. Files you saved inside the "
                    + "guest and images you pulled with docker live on a separate data "
                    + "disk and are kept; a backup of that disk is written first anyway.");
        } else {
            m.append("The guest image has to be downloaded once");
            if (mb > 0) m.append(" (").append(mb).append(" MB)");
            m.append("; the APK does not carry it.\n\nIt is what makes the guest "
                    + "Alpine with docker and a real shell. Without it the app boots "
                    + "a small rescue shell instead.");
        }
        AlertDialog.Builder b = new AlertDialog.Builder(this)
                .setTitle(present ? "New guest image" : "Guest image")
                .setMessage(m.toString())
                .setPositiveButton(present ? "Reinstall" : "Download",
                        new DialogInterface.OnClickListener() {
                            @Override public void onClick(DialogInterface d, int which) {
                                downloadImage(rel);
                            }
                        });
        if (present) {
            b.setNeutralButton("Back up first", new DialogInterface.OnClickListener() {
                @Override public void onClick(DialogInterface d, int which) {
                    backupThenAsk(rel);
                }
            });
        }
        b.setNegativeButton(present ? "Keep" : "Not now",
                new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface d, int which) {
                        if (present)
                            prefs.edit().putString(IMAGE_SKIPPED, rel.tag).apply();
                    }
                })
                .show();
    }

    /**
     * The update dialog's "Back up first": copy the data disk, then ask the
     * same question again so the reinstall is one tap away. The copy that
     * matters is the automatic one in runImageDownload, which happens even when
     * this is never pressed; this is for someone who wants the backup before
     * deciding.
     */
    private void backupThenAsk(final Release rel) {
        if (guestData() == null) { toast("there is no data disk to back up yet"); return; }
        final Progress p = progressDialog("Backing up guest data");
        new Thread(new Runnable() {
            @Override public void run() { runBackupThenAsk(rel, p); }
        }, "umarm-backup-update").start();
    }

    private void runBackupThenAsk(Release rel, Progress p) {
        String name = null, err = null;
        try {
            File data = guestData();
            if (data == null) throw new IOException("there is no data disk");
            File out = new File(backupsDir(), BACKUP_PREFIX + stamp() + BACKUP_SUFFIX);
            gzipFile(data, out, p);
            pruneBackups();
            name = out.getName();
            log("backed up the data disk to " + name + "\n");
        } catch (Exception e) {
            err = e.toString();
            log("backup failed: " + err + "\n");
        }
        finishBackupThenAsk(p, name, err, rel);
    }

    private void finishBackupThenAsk(final Progress p, final String name,
            final String err, final Release rel) {
        ui.post(new Runnable() {
            @Override public void run() {
                p.dialog.dismiss();
                if (err != null) toast("backup failed: " + err);
                else toast("backed up to " + name);
                askImage(rel, true);
            }
        });
    }

    private void askAppUpdate(final Release rel, final boolean have) {
        final File apk = new File(getCacheDir(), ApkProvider.NAME);
        long mb = rel.size > 0 ? rel.size >> 20 : 0;
        StringBuilder m = new StringBuilder();
        m.append("umarm ").append(rel.version).append(" is available");
        if (mb > 0) m.append(" (").append(mb).append(" MB)");
        m.append(".\n\nThe APK is signed with the same key, so Android takes it as an "
                + "update and the guest image is left alone.");
        new AlertDialog.Builder(this)
                .setTitle("App update")
                .setMessage(m.toString())
                .setPositiveButton(have ? "Install" : "Download",
                        new DialogInterface.OnClickListener() {
                            @Override public void onClick(DialogInterface d, int which) {
                                if (have) installUpdate(apk); else downloadAppUpdate(rel);
                            }
                        })
                .setNegativeButton("Not now", new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface d, int which) {
                        prefs.edit().putString(APP_SKIPPED, rel.version).apply();
                    }
                })
                .show();
    }

    /**
     * Is the APK in the cache the one this release offers?
     *
     * The file's length alone cannot answer that. build-apk.sh's output has
     * landed on the same byte count for several consecutive recipes -- five
     * umarm-* releases all weighed 27735863 bytes, with different md5s -- so a
     * cached file from one release made the next one of that size look already
     * downloaded, and the package installer was handed the old build instead
     * of the new one being fetched. The md5 in the release manifest is what
     * names the bytes, so that is what decides. A release whose body is not a
     * manifest has no md5 to compare, and there the size is all there is.
     */
    private boolean cachedAppUpdate(Release rel) {
        File apk = new File(getCacheDir(), ApkProvider.NAME);
        if (!apk.exists() || apk.length() == 0)
            return false;
        if (rel.md5.length() == 0)
            return rel.size > 0 && apk.length() == rel.size;
        return rel.md5.equalsIgnoreCase(fileMd5(apk));
    }

    /** The md5 of a file, or "" when it cannot be read. */
    private static String fileMd5(File f) {
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("MD5");
        } catch (Exception e) {
            return "";
        }
        InputStream in = null;
        try {
            in = new FileInputStream(f);
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = in.read(buf)) > 0) digest.update(buf, 0, n);
            return hex(digest.digest());
        } catch (IOException e) {
            return "";
        } finally {
            if (in != null) try { in.close(); } catch (IOException e) { }
        }
    }

    /*
     * Download and verify a release asset into the cache, and then either install
     * it as the guest image or hand it to the package installer.
     *
     * The modal cannot be dismissed by tapping outside: a cancelled download is a
     * temp file, but the image install replaces a 1 GiB filesystem and the app
     * update restarts the app. Both run on a thread, and the thread bodies are
     * named methods -- an anonymous class declared inside the run() of another
     * one compiles to MainActivity$N$1 and d8 8.2 rejects that shape with an
     * internal NullPointerException. See the note on logFile above.
     */
    private static final class Progress {
        AlertDialog dialog;
        ProgressBar bar;
        TextView label;
        final boolean[] cancelled = { false };
    }

    private Progress progressDialog(String title) {
        final Progress p = new Progress();
        p.bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        p.bar.setMax(100);
        p.label = new TextView(this);
        p.label.setText("starting ...");
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.VERTICAL);
        v.setPadding(dp(24), dp(16), dp(24), dp(16));
        v.addView(p.label);
        v.addView(p.bar);
        p.dialog = new AlertDialog.Builder(this)
                .setTitle(title)
                .setView(v)
                .setCancelable(false)
                .create();
        p.dialog.setButton(DialogInterface.BUTTON_NEGATIVE, "Cancel",
                new DialogInterface.OnClickListener() {
                    @Override public void onClick(DialogInterface d, int which) {
                        p.cancelled[0] = true;
                    }
                });
        p.dialog.show();
        return p;
    }

    private void downloadImage(final Release rel) {
        if (isGuestRunning()) {
            toast("stop the guest first");
            return;
        }
        final Progress p = progressDialog("Guest image " + rel.tag);
        new Thread(new Runnable() {
            @Override public void run() { runImageDownload(rel, p); }
        }, "umarm-image-download").start();
    }

    private void runImageDownload(Release rel, Progress p) {
        String err = null;
        String ok = "guest image " + rel.tag + " installed -- Boot to use it";
        try {
            File gz = downloadToCache(rel, IMAGE_ASSET, p);
            if (gz == null) {
                ok = null;                             /* cancelled */
            } else {
                /*
                 * The data disk is a different file and the install below only
                 * replaces the base, so the user's data survives the update
                 * whether or not this succeeds. It is copied anyway, because
                 * "your data is kept" is worth being able to prove, and because
                 * it is the only history a reinstall leaves behind.
                 */
                String bak = backupBeforeUpdate(rel, p);
                installImage(gz, rel.tag, p);
                if (bak != null)
                    ok = "guest image " + rel.tag + " installed (data backed up to "
                            + bak + ") -- Boot to use it";
            }
        } catch (Exception e) {
            err = e.toString();
            ok = null;
        }
        finishDownload(p, ok, err);
    }

    private void downloadAppUpdate(final Release rel) {
        final Progress p = progressDialog("umarm " + rel.version);
        new Thread(new Runnable() {
            @Override public void run() { runAppDownload(rel, p); }
        }, "umarm-app-download").start();
    }

    private void runAppDownload(Release rel, Progress p) {
        File apk = null;
        String err = null;
        try {
            apk = downloadToCache(rel, ApkProvider.NAME, p);
        } catch (Exception e) {
            err = e.toString();
        }
        finishDownload(p, null, err);
        if (apk != null && !p.cancelled[0])
            installUpdateFromThread(apk);
    }

    /* Main-thread hop in a named method, for the same d8 reason as above. */
    private void installUpdateFromThread(final File apk) {
        ui.post(new Runnable() {
            @Override public void run() { installUpdate(apk); }
        });
    }

    /**
     * Download a release asset into the cache, repainting the dialog at most once
     * per megabyte, and check it against the md5 the manifest advertised. Returns
     * the file, or null when Cancel was pressed.
     */
    private File downloadToCache(Release rel, String name, Progress p) throws IOException {
        File out = new File(getCacheDir(), name);
        File part = new File(getCacheDir(), name + ".part");
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("MD5");
        } catch (Exception e) {
            digest = null;
        }

        HttpURLConnection c = (HttpURLConnection) new URL(rel.url).openConnection();
        c.setInstanceFollowRedirects(true);
        c.setConnectTimeout(20000);
        c.setReadTimeout(60000);
        c.setRequestProperty("User-Agent", "umarm");
        c.setRequestProperty("Accept", "application/octet-stream");
        try {
            int code = c.getResponseCode();
            if (code != 200)
                throw new IOException("HTTP " + code + " from " + rel.url);
            long total = c.getContentLength();
            if (total <= 0) total = rel.size;

            InputStream in = c.getInputStream();
            FileOutputStream fos = new FileOutputStream(part);
            byte[] buf = new byte[1 << 16];
            long done = 0, last = 0;
            int n;
            while ((n = in.read(buf)) > 0) {
                if (p.cancelled[0]) {
                    in.close();
                    fos.close();
                    part.delete();
                    return null;
                }
                fos.write(buf, 0, n);
                if (digest != null) digest.update(buf, 0, n);
                done += n;
                if (done - last >= (1L << 20)) {
                    last = done;
                    progress(p, "downloading", done, total);
                }
            }
            fos.close();
            in.close();
            progress(p, "verifying", done, total);

            if (rel.md5.length() > 0 && digest != null) {
                String got = hex(digest.digest());
                if (!rel.md5.equalsIgnoreCase(got))
                    throw new IOException("md5 mismatch (expected " + rel.md5
                            + ", got " + got + ")");
            }
            if (out.exists() && !out.delete())
                throw new IOException("cannot replace " + out);
            if (!part.renameTo(out))
                throw new IOException("cannot rename " + part);
            return out;
        } finally {
            c.disconnect();
        }
    }

    private void finishDownload(final Progress p, final String ok, final String err) {
        ui.post(new Runnable() {
            @Override public void run() {
                p.dialog.dismiss();
                if (err != null) {
                    log("download failed: " + err + "\n");
                    toast("could not install it: " + err);
                } else if (p.cancelled[0]) {
                    toast("cancelled");
                } else if (ok != null) {
                    toast(ok);
                }
            }
        });
    }

    /*
     * The same for the data-disk operations, which are not downloads. One level
     * of anonymous class only, for the d8 reason above.
     */
    private void finishOp(final Progress p, final String ok, final String err) {
        ui.post(new Runnable() {
            @Override public void run() {
                p.dialog.dismiss();
                if (err != null) toast("failed: " + err);
                else if (p.cancelled[0]) toast("cancelled");
                else if (ok != null) toast(ok);
            }
        });
    }

    /** Unpack the downloaded archive onto the image the guest boots. */
    private void installImage(File gz, String tag, Progress p) throws IOException {
        File out = new File(getFilesDir(), IMAGE_NAME);
        File neu = new File(getFilesDir(), IMAGE_NAME + ".new");

        /*
         * The bar's maximum comes from the gzip trailer, not from the download.
         * The extractor turns a 110 MB archive into a 1 GiB image and never says
         * how much is left, so a bar driven only by the download would sit
         * wherever the download left it -- full. ISIZE is the uncompressed size,
         * and a single-member gzip (what `gzip -c` writes, and what the release
         * carries) puts it in the last four bytes.
         */
        long raw = gzipIsize(gz);
        progress(p, "unpacking", 0, raw);
        InputStream in = new GZIPInputStream(new FileInputStream(gz), 65536);
        FileOutputStream fos = new FileOutputStream(neu);
        byte[] buf = new byte[1 << 16];
        long total = 0, last = 0;
        int n;
        while ((n = in.read(buf)) > 0) {
            fos.write(buf, 0, n);
            total += n;
            /* Repaint every 8 MB: 1 GiB is 128 steps, and not 16 000 posts. */
            if (total - last >= (8L << 20)) {
                last = total;
                progress(p, "unpacking", total, raw);
            }
        }
        fos.close();
        in.close();
        progress(p, "unpacking", total, raw);

        if (out.exists() && !out.delete())
            throw new IOException("cannot replace " + out);
        if (!neu.renameTo(out))
            throw new IOException("cannot rename " + neu + " to " + out);

        setInstalledImageVersion(tag);
        /*
         * The archive carries the release's 1 GiB image, so a grown base would
         * come back small. The user's desired size is a preference, not a
         * property of the file, so it is applied again here -- grow-only, so a
         * release that shipped larger is left alone.
         */
        if (desiredBaseSize() > 0) growFile(out, desiredBaseSize());
        /*
         * A freshly installed image is a fresh install, and the guest's init
         * reads this file to offer first-run setup -- it creates the non-root
         * user and, from then on, logs in as it. Written here and not baked into
         * the image so that the wizard is an app boot: the image the harness and
         * the CI gates boot has no marker, and neither does the second boot,
         * because the guest removes it.
         */
        File marker = new File(getFilesDir(), "first-run");
        if (!marker.exists() && !marker.createNewFile())
            log("cannot create the first-run marker; the guest boots as root\n");
        gz.delete();
        log("installed the guest image " + tag + " (" + (total >> 20) + " MB)\n");
    }

    /**
     * Hand the downloaded APK to the package installer.
     *
     * Two things have to be true first, and Android reports neither of them in
     * the install screen: the app has to be allowed to request installs at all
     * (REQUEST_INSTALL_PACKAGES, a per-app switch in Settings since Android 8),
     * and the file has to reach the installer through a content:// URI, because a
     * file:// path out of an app's private storage raises FileUriExposedException.
     * ApkProvider is the second of those; this is the first.
     */
    private void installUpdate(File apk) {
        if (Build.VERSION.SDK_INT >= 26 && !getPackageManager().canRequestPackageInstalls()) {
            new AlertDialog.Builder(this)
                    .setTitle("Allow umarm to install updates")
                    .setMessage("Android needs this switch on before the app can install a "
                            + "downloaded update. The APK is already downloaded; come back "
                            + "and check for updates again.")
                    .setPositiveButton("Open settings", new DialogInterface.OnClickListener() {
                        @Override public void onClick(DialogInterface d, int which) {
                            try {
                                startActivity(new Intent(
                                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:" + getPackageName())));
                            } catch (Exception e) {
                                toast("no settings screen for this: " + e);
                            }
                        }
                    })
                    .setNegativeButton("Cancel", null)
                    .show();
            return;
        }
        Intent i = new Intent(Intent.ACTION_VIEW);
        i.setDataAndType(ApkProvider.uri(), "application/vnd.android.package-archive");
        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        try {
            startActivity(i);
        } catch (Exception e) {
            log("could not start the installer: " + e + "\n");
            toast("could not start the installer: " + e);
        }
    }

    /** The build identity build-apk.sh baked into the manifest. */
    private String recipe() {
        try {
            ApplicationInfo ai = getPackageManager()
                    .getApplicationInfo(getPackageName(), PackageManager.GET_META_DATA);
            if (ai == null || ai.metaData == null) return "";
            String r = ai.metaData.getString("org.umarm.recipe", "");
            /* An unsubstituted placeholder means the manifest never went through
             * build-apk.sh; "unknown" is better than comparing the literal with a
             * release digest and offering an update forever. */
            return r == null || r.startsWith("__") ? "" : r;
        } catch (Exception e) {
            return "";
        }
    }

    /** Repaint the download dialog, at most once per megabyte. */
    private void progress(final Progress p, final String what,
            final long done, final long total) {
        ui.post(new Runnable() {
            @Override public void run() {
                if (total > 0) {
                    if (p.bar.isIndeterminate()) p.bar.setIndeterminate(false);
                    p.bar.setProgress((int) (done * 100 / total));
                } else if (!p.bar.isIndeterminate()) {
                    /* No total to divide by: an animated bar and the megabyte
                     * count, rather than a full bar that means nothing. */
                    p.bar.setIndeterminate(true);
                }
                p.label.setText(what + "  " + (done >> 20)
                        + (total > 0 ? " / " + (total >> 20) : "") + " MB");
            }
        });
    }

    /**
     * The uncompressed size of a gzip file, from its trailer.
     *
     * The last four bytes of a single-member gzip are ISIZE: the uncompressed
     * size modulo 2^32, little-endian. That is the only way to learn how big the
     * image will be before extracting it -- a GZIPInputStream does not report a
     * total. A multi-member archive would leave only the last member's size
     * here, so the value is a hint: progress() falls back to an indeterminate
     * bar when it is zero, which is also what a 4 GiB image wraps to.
     */
    private static long gzipIsize(File f) {
        RandomAccessFile ra = null;
        try {
            ra = new RandomAccessFile(f, "r");
            if (ra.length() < 4) return 0;
            ra.seek(ra.length() - 4);
            long v = 0;
            for (int i = 0; i < 4; i++) v |= ((long) ra.read()) << (8 * i);
            return v;
        } catch (IOException e) {
            return 0;
        } finally {
            if (ra != null) try { ra.close(); } catch (IOException e) { }
        }
    }

    /** A small HTTPS GET: the releases API and the asset both answer to this. */
    private String httpGet(String url, int timeoutMs) throws IOException {
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setInstanceFollowRedirects(true);
        c.setConnectTimeout(timeoutMs);
        c.setReadTimeout(timeoutMs);
        c.setRequestProperty("User-Agent", "umarm");
        c.setRequestProperty("Accept", "application/vnd.github+json");
        try {
            int code = c.getResponseCode();
            if (code != 200)
                throw new IOException("HTTP " + code + " from " + url);
            InputStream in = c.getInputStream();
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            in.close();
            return new String(out.toByteArray(), "UTF-8");
        } finally {
            c.disconnect();
        }
    }

    private static String hex(byte[] b) {
        StringBuilder s = new StringBuilder(b.length * 2);
        for (byte x : b) {
            s.append(Character.forDigit((x >> 4) & 0xf, 16));
            s.append(Character.forDigit(x & 0xf, 16));
        }
        return s.toString();
    }

    /** Toast from a background thread. */
    private void post(final String s) {
        ui.post(new Runnable() {
            @Override public void run() { toast(s); }
        });
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
