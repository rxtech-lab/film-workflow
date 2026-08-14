export async function GET(
  _request: Request,
  { params }: { params: Promise<{ flow: string }> }
) {
  const { flow } = await params;

  if (flow !== "signin" && flow !== "signup") {
    return new Response("Not Found", { status: 404 });
  }

  const isSignUp = flow === "signup";

  const schema = {
    flow,
    title: isSignUp ? "Create Account" : "Sign In",
    submitLabel: isSignUp ? "Create Account" : "Sign In",
    fields: [
      {
        key: "username",
        label: "Email",
        placeholder: "you@example.com",
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
              label: "Name",
              placeholder: "Your name",
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
        label: "Password",
        placeholder: "Password",
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
        label: isSignUp ? "Create Account" : "Sign In",
        primary: true,
      },
    ],
    links: null,
  };

  return Response.json(schema, {
    headers: { "Cache-Control": "public, max-age=300" },
  });
}
