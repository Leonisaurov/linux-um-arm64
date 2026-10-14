package org.umarm.debian;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.FileNotFoundException;

/**
 * The one file the package installer has to be able to read: the update this app
 * downloaded.
 *
 * It exists because of a rule that is easy to be surprised by. Since Android 7,
 * a file:// URI handed to another app raises FileUriExposedException -- an app
 * may not hand out a raw path into its own private storage -- so the installer
 * has to be given a content:// URI and read it through a provider. androidx.core
 * ships FileProvider for exactly this, and androidx.core is not linked here: the
 * app has no Gradle, no dependency resolution and no AAR handling, and one file
 * does not justify building that. This is the part of FileProvider that matters,
 * made as narrow as it can be: one name, in the cache directory, read only, and
 * not exported. The URI permission is granted for the single start intent, so
 * nothing else can read it either.
 */
public class ApkProvider extends ContentProvider {

    /** The authority in the manifest and the URI built here have to agree. */
    static final String AUTHORITY = "org.umarm.debian.apk";
    /** The name inside the cache directory, and the last path segment. */
    static final String NAME = "umarm.apk";

    static Uri uri() {
        return Uri.parse("content://" + AUTHORITY + "/" + NAME);
    }

    private File apk() {
        return new File(getContext().getCacheDir(), NAME);
    }

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        /*
         * Read only, and only for the one name: a provider that opens whatever
         * path it is handed is how the file-descriptor leaks happened.
         */
        if (!NAME.equals(uri.getLastPathSegment()))
            throw new FileNotFoundException(uri.toString());
        return ParcelFileDescriptor.open(apk(), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override
    public String getType(Uri uri) {
        return "application/vnd.android.package-archive";
    }

    /*
     * The installer asks for the display name and the size before it opens the
     * file, and a provider that answers null to query() is a provider some
     * installers refuse. MatrixCursor is the framework's own in-memory answer.
     */
    @Override
    public Cursor query(Uri uri, String[] projection, String selection,
            String[] selectionArgs, String sortOrder) {
        String[] cols = { "_display_name", "_size" };
        MatrixCursor c = new MatrixCursor(cols, 1);
        c.addRow(new Object[] { NAME, apk().length() });
        return c;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }
}
