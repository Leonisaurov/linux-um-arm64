package androidx.annotation;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * A compile-time-only stand-in for {@code androidx.annotation.RequiresApi}. See
 * {@link NonNull} for why these are vendored as stubs.
 *
 * The terminal sources call it as {@code @RequiresApi(api = Build.VERSION_CODES.O)},
 * so the attribute is named {@code api}. {@code value} exists because the real
 * annotation has both and callers may use either.
 */
@Retention(RetentionPolicy.CLASS)
@Target({
    ElementType.TYPE,
    ElementType.METHOD,
    ElementType.CONSTRUCTOR,
    ElementType.FIELD,
    ElementType.PACKAGE,
})
public @interface RequiresApi {
    int api() default 1;

    int value() default 1;
}
