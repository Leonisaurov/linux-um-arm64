package androidx.annotation;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * A compile-time-only stand-in for {@code androidx.annotation.NonNull}.
 *
 * The vendored Termux terminal sources annotate their signatures with three
 * androidx annotations, and the app is built without Gradle -- so without an
 * androidx dependency there is nothing for javac to resolve them against. They
 * are only hints: nothing reads them at runtime, and {@code @Retention(CLASS)}
 * means they do not even reach the dex. Vendoring the real jar would mean the
 * app's build acquired a network dependency for three marker types.
 */
@Retention(RetentionPolicy.CLASS)
@Target({
    ElementType.METHOD,
    ElementType.PARAMETER,
    ElementType.FIELD,
    ElementType.LOCAL_VARIABLE,
    ElementType.TYPE_USE,
    ElementType.TYPE_PARAMETER,
})
public @interface NonNull {
}
