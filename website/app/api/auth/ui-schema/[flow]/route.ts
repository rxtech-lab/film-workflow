import { localeHeaders } from "@/lib/i18n/locale";
import { requestLocale } from "@/lib/i18n/request";
import { t } from "@/lib/i18n/messages";

/**
 * The sign-in and sign-up forms the app draws. Labels follow the caller's
 * `Accept-Language`, so the form matches the language the rest of the app is
 * in; the field keys, types and autocomplete hints never change with it.
 */
export async function GET(
  request: Request,
  { params }: { params: Promise<{ flow: string }> }
) {
  const { flow } = await params;

  if (flow !== "signin" && flow !== "signup") {
    return new Response("Not Found", { status: 404 });
  }

  const isSignUp = flow === "signup";
  const locale = await requestLocale(request);
  const submitLabel = t(locale, isSignUp ? "auth.signUp.title" : "auth.signIn.title");

  const schema = {
    flow,
    title: submitLabel,
    submitLabel,
    fields: [
      {
        key: "username",
        label: t(locale, "auth.field.email"),
        placeholder: t(locale, "auth.field.email.placeholder"),
        type: "email",
        isPassword: false,
        required: true,
        autocomplete: "username",
        validation: null,
      },
      ...(isSignUp
        ? [
            {
              key: "name",
              label: t(locale, "auth.field.name"),
              placeholder: t(locale, "auth.field.name.placeholder"),
              type: "name",
              isPassword: false,
              required: false,
              autocomplete: "name",
              validation: null,
            },
          ]
        : []),
      {
        key: "password",
        label: t(locale, "auth.field.password"),
        placeholder: t(locale, "auth.field.password"),
        type: "password",
        isPassword: true,
        required: true,
        autocomplete: isSignUp ? "new-password" : "current-password",
        validation: isSignUp
          ? { minLength: 8, maxLength: null, pattern: null, patternMessage: null }
          : null,
      },
    ],
    supportedMethods: [
      {
        id: "password",
        label: submitLabel,
        primary: true,
      },
    ],
    links: null,
  };

  return Response.json(schema, {
    // Cached for five minutes, but per language: without `Vary` a shared cache
    // would hand the next caller whichever language warmed it.
    headers: localeHeaders(locale, { "Cache-Control": "public, max-age=300" }),
  });
}
