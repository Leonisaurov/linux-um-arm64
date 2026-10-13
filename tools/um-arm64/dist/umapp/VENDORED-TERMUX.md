Termux terminal emulator, vendored
=================================

src/com/termux/terminal/**, src/com/termux/view/**, res/**, jni/termux.c and
the corresponding resource tree are copied from the Termux app:

    https://github.com/termux/termux-app
    modules terminal-emulator and terminal-view

licensed under the Apache License, Version 2.0 (LICENSE-TERMINAL-EMULATOR,
alongside this file). The app is built without Gradle, so the modules are
vendored as sources rather than consumed as dependencies, and three local
adjustments are made:

  * res/drawable/text_select_handle_{left,right}_material.xml: the fill color
    was `?attr/colorSecondary`, a Material-Components theme attribute the app
    does not have; it is now a literal color. The handles are cosmetic and
    nothing else in the tree references that attribute.

  * src/com/termux/terminal/TerminalBitmap.java: `Build.VERSION_CODES
    .VANILLA_ICE_CREAM` (API 35) is written as the literal `35`, so the app
    compiles against an android.jar older than 35. The value is identical.

  * src/androidx/annotation/{NonNull,Nullable,RequiresApi}.java: the vendored
    sources annotate signatures with these three androidx types. They are
    compile-time markers only; the stubs keep the build free of a network
    dependency for three annotations that do not survive into the dex.

  * build-apk.sh passes `--extra-packages com.termux.view --extra-packages
    com.termux.terminal` to aapt2, so the vendored sources resolve their own
    R class the way a Gradle library module would.
