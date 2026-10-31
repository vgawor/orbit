// Public settings for the phone web app and the checkout page. Nothing here is secret:
// the publishable key and the Paddle client-side token are meant to be in web pages.
window.ORBIT = {
  supabaseUrl: "https://agxhwmdzbdatvsjuvsma.supabase.co",
  publishableKey: "sb_publishable_g7gLn8wqHiC2bCUuVddAiQ_JNUDwx5i",
  // Paddle → Developer tools → Authentication → Client-side tokens (starts with "test_" in sandbox, "live_" when live).
  paddleClientToken: "",
  // "sandbox" while testing, "production" when Orbit Pro goes on sale.
  paddleEnvironment: "sandbox",
};
