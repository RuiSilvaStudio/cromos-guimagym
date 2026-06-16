import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY");

const MODELS = [
  "gemini-2.5-flash",
  "gemini-2.5-flash-lite",
];

const MAX_SCANS_PER_MONTH = 100;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const PROMPT = `This is a photo of a GuimaGym gym membership sticker. The sticker has this exact layout:
- "GUIMAGYM" logo in the top-left area
- A person's photo in the center
- A name written vertically on the right side (e.g. "ALICE SILVA")
- A category below the name (e.g. "KIDS GYM")
- THE STICKER NUMBER: a 3-digit number (with leading zeros, like 021, 142, 003) printed in WHITE text inside a SMALL BLACK SQUARE in the BOTTOM-RIGHT corner of the sticker.

Your ONLY task: read the 3-digit number from that black square in the bottom-right corner.
Reply with ONLY the 3 digits. Nothing else. No explanation. Just the number.`;

async function callGemini(imageBase64: string): Promise<string> {
  for (const model of MODELS) {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_API_KEY}`;

    const payload = {
      contents: [
        {
          parts: [
            { text: PROMPT },
            {
              inline_data: {
                mime_type: "image/jpeg",
                data: imageBase64,
              },
            },
          ],
        },
      ],
      generationConfig: {
        temperature: 0,
        maxOutputTokens: 256,
        thinkingConfig: { thinkingBudget: 0 },
      },
      safetySettings: [
        { category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_NONE" },
        { category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_NONE" },
        { category: "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold: "BLOCK_NONE" },
        { category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_NONE" },
      ],
    };

    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(30000),
    });

    if (!res.ok) {
      console.error(`Gemini ${model} error: ${res.status}`);
      continue;
    }

    const data = await res.json();
    const text = data?.candidates?.[0]?.content?.parts?.[0]?.text?.trim() ?? "";
    if (text) return text;
  }

  return "";
}

function extractNumber(text: string): string | null {
  const match = text.match(/\d{3}/);
  if (!match) return null;
  const num = parseInt(match[0], 10);
  if (num >= 1 && num <= 788) return match[0].padStart(3, "0");
  return null;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supa = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: authError } = await supa.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const now = new Date();
    const month = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}`;

    const supaAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const { data: usage } = await supaAdmin
      .from("scan_usage")
      .select("count")
      .eq("user_id", user.id)
      .eq("month", month)
      .single();

    const currentCount = usage?.count ?? 0;
    if (currentCount >= MAX_SCANS_PER_MONTH) {
      return new Response(
        JSON.stringify({
          error: "monthly_limit",
          message: `Limite mensal de ${MAX_SCANS_PER_MONTH} escaneamentos atingido.`,
          used: currentCount,
          limit: MAX_SCANS_PER_MONTH,
        }),
        {
          status: 429,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const { image } = await req.json();
    if (!image) {
      return new Response(JSON.stringify({ error: "Missing image" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    let stickerNumber = null;

    try {
      const text = await callGemini(image);
      stickerNumber = extractNumber(text);
    } catch (e) {
      console.error("scan-sticker error:", e);
    }

    await supaAdmin.rpc("increment_scan_usage", {
      p_user_id: user.id,
      p_month: month,
    });

    const remaining = MAX_SCANS_PER_MONTH - (currentCount + 1);

    if (stickerNumber) {
      return new Response(
        JSON.stringify({ number: stickerNumber, used: currentCount + 1, limit: MAX_SCANS_PER_MONTH, remaining }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    } else {
      return new Response(
        JSON.stringify({ error: "not_found", message: "Nao consegui ler o numero da figurinha.", used: currentCount + 1, limit: MAX_SCANS_PER_MONTH, remaining }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
  } catch (err) {
    console.error("scan-sticker error:", err);
    return new Response(
      JSON.stringify({ error: "server_error", message: "Erro interno." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
