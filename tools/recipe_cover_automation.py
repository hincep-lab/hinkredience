"""Safe recipe-cover automation. Dry-run by default; requires explicit --apply.

No app code or schema changes. Requires Python 3.11+ and only stdlib.
"""
import argparse
import base64
import json
import os
import sys
import uuid
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

BUCKET = "recipe-photos"
MAX_IMAGES = 5
MAX_IMAGE_BYTES = 10_000_000


def request(method, url, headers=None, body=None):
    req = Request(url, data=body, method=method, headers=headers or {})
    try:
        with urlopen(req, timeout=90) as resp:
            data = resp.read()
            return json.loads(data) if data else None
    except HTTPError as exc:
        # Avoid logging response payloads containing user data or credentials.
        raise RuntimeError(f"{method} returned HTTP {exc.code}") from exc


def config():
    base = os.environ["SUPABASE_URL"].rstrip("/")
    if not base.startswith("https://"):
        raise RuntimeError("SUPABASE_URL must be HTTPS")
    key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    owner = os.environ["HINK_OWNER_ID"]
    uuid.UUID(owner)
    return base, key, owner


def headers(key, **extra):
    return {"apikey": key, "Authorization": "Bearer " + key, **extra}


def candidates(base, key, owner):
    url = (base + "/rest/v1/recipes?" + urlencode({
        "select": "id,title,description,ingredients:recipe_ingredients(name),photos,owner_id",
        "owner_id": "eq." + owner,
        "deleted_at": "is.null",
        "order": "created_at.asc",
        "limit": "300",
    }))
    # Return all items; select first eligible up to MAX_IMAGES in main.
    data = request("GET", url, headers(key))
    return [r for r in data if r.get("photos") == []]


def generate_image(recipe):
    key = os.environ["OPENAI_API_KEY"]
    names = [str(x.get("name", "")) for x in recipe.get("ingredients", [])[:15]]
    prompt = (
        "One single photorealistic professional food photograph of the finished dish: "
        + recipe["title"] + ". " + str(recipe.get("description") or "")[:450]
        + ". Ingredients: " + ", ".join(names)[:600]
        + ". Accurate food, appetizing plating, natural lighting, "
        "no collage, no text, no watermark, no people."
    )
    payload = json.dumps({
        "model": os.getenv("HINK_IMAGE_MODEL", "gpt-image-1.5"),
        "size": "1024x1024",
        "n": 1,
        "prompt": prompt,
    }).encode()
    data = request("POST", "https://api.openai.com/v1/images/generations",
                   {"Authorization": "Bearer " + key, "Content-Type": "application/json"}, payload)
    encoded = data["data"][0]["b64_json"]
    img = base64.b64decode(encoded, validate=True)
    if not img.startswith(b"\x89PNG\r\n\x1a\n") or len(img) > MAX_IMAGE_BYTES:
        raise RuntimeError("Generated image is not a valid PNG within the size limit")
    return img


def upload(base, key, path, content):
    url = base + "/storage/v1/object/" + BUCKET + "/" + quote(path, safe="/")
    return request("POST", url, headers(key, **{"Content-Type": "image/png", "x-upsert": "false"}), content)


def remove(base, key, path):
    url = base + "/storage/v1/object/" + BUCKET + "/" + quote(path, safe="/")
    request("DELETE", url, headers(key))


def attach_if_empty(base, key, owner, recipe_id, photo_id, path):
    # Optimistic condition: only add a cover when photos is still empty.
    # Never overwrite or prepend to an existing photo collection.
    filters = urlencode({
        "id": "eq." + recipe_id,
        "owner_id": "eq." + owner,
        "photos": "eq.[]",
        "deleted_at": "is.null",
    })
    url = base + "/rest/v1/recipes?" + filters
    data = json.dumps({
        "photos": [{"id": photo_id, "remote_path": path}],
        "updated_at": __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc).isoformat(),
    }).encode()
    result = request("PATCH", url, headers(key, **{
        "Content-Type": "application/json", "Prefer": "return=representation"
    }), data)
    return isinstance(result, list) and len(result) == 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true",
                        help="Enable paid image generation and database/storage writes")
    parser.add_argument("--limit", type=int, default=1)
    args = parser.parse_args()
    if not 1 <= args.limit <= MAX_IMAGES:
        parser.error("limit must be between 1 and 5")
    base, key, owner = config()
    recipes = candidates(base, key, owner)
    print(f"Found {len(recipes)} recipes without photos.")
    for recipe in recipes[:args.limit]:
        print(f"Candidate: {recipe['id']} - {recipe['title']}")
        if not args.apply:
            continue
        photo_id = str(uuid.uuid4())
        path = f"{owner}/{recipe['id']}/{photo_id}.png"
        content = generate_image(recipe)
        upload(base, key, path, content)
        try:
            if not attach_if_empty(base, key, owner, recipe["id"], photo_id, path):
                print("Skipped: photo was added concurrently.")
                remove(base, key, path)
            else:
                print("Cover saved.")
        except Exception:
            try:
                remove(base, key, path)
            except Exception:
                print("Warning: orphaned uploaded object; manual cleanup needed.", file=sys.stderr)
            raise


if __name__ == "__main__":
    main()
