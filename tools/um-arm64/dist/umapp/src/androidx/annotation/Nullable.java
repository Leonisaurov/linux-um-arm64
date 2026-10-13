package androidx.annotation;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * A compile-time-only stand-in for {@code androidx.annotation.Nullable}. See
 * {@link NonNull} for why these are vendored as stubs.
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
public @interface Nullable {
}
