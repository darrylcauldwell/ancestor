"""MLX LLM wrapper — load model, generate, parse JSON responses.

MLX is optional. If not installed, ask() and ask_json() return None
and the agent falls back to the deterministic analyser.
"""

import json
from agent.config import MODEL_NAME, MAX_TOKENS, MAX_RETRIES

try:
    from mlx_lm import load, generate
    _MLX_AVAILABLE = True
except ImportError:
    _MLX_AVAILABLE = False

_model = None
_tokenizer = None


def _ensure_loaded():
    """Load model on first use. Returns False if MLX not available."""
    global _model, _tokenizer
    if not _MLX_AVAILABLE:
        return False
    if _model is None:
        print(f"Loading {MODEL_NAME}...")
        _model, _tokenizer = load(MODEL_NAME)
        print("Model loaded.")
    return True


def ask(prompt: str, system: str = "") -> str | None:
    """Send a prompt to the LLM and return the raw text response."""
    if not _ensure_loaded():
        return None

    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    formatted = _tokenizer.apply_chat_template(
        messages,
        add_generation_prompt=True,
        tokenize=False,
    )

    response = generate(
        _model,
        _tokenizer,
        prompt=formatted,
        max_tokens=MAX_TOKENS,
    )
    return response.strip()


def ask_json(prompt: str, system: str = "") -> dict | list | None:
    """Send a prompt and parse the response as JSON.

    Retries up to MAX_RETRIES times if JSON parsing fails.
    Returns None if all attempts fail.
    """
    for attempt in range(MAX_RETRIES + 1):
        raw = ask(prompt, system)
        if raw is None:
            return None

        # Try to extract JSON from the response
        parsed = _extract_json(raw)
        if parsed is not None:
            return parsed

        if attempt < MAX_RETRIES:
            print(f"  JSON parse failed (attempt {attempt + 1}), retrying...")
            prompt_with_reminder = (
                prompt + "\n\nIMPORTANT: Respond with valid JSON only. "
                "No markdown, no explanation, just the JSON object."
            )
            raw = ask(prompt_with_reminder, system)
            parsed = _extract_json(raw)
            if parsed is not None:
                return parsed

    print(f"  WARNING: Failed to get valid JSON after {MAX_RETRIES + 1} attempts")
    print(f"  Raw response: {raw[:500]}")
    return None


def _extract_json(text: str) -> dict | list | None:
    """Try to extract JSON from text that might contain markdown or extra text."""
    # Try direct parse
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Try extracting from ```json ... ``` blocks
    if "```json" in text:
        start = text.index("```json") + 7
        end = text.index("```", start)
        try:
            return json.loads(text[start:end].strip())
        except (json.JSONDecodeError, ValueError):
            pass

    # Try extracting from ``` ... ``` blocks
    if "```" in text:
        start = text.index("```") + 3
        end = text.index("```", start)
        try:
            return json.loads(text[start:end].strip())
        except (json.JSONDecodeError, ValueError):
            pass

    # Try finding first { or [ and matching closing bracket
    for start_char, end_char in [("{", "}"), ("[", "]")]:
        start = text.find(start_char)
        if start == -1:
            continue
        # Find matching close by scanning from the end
        end = text.rfind(end_char)
        if end > start:
            try:
                return json.loads(text[start:end + 1])
            except json.JSONDecodeError:
                pass

    return None
