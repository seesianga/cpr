#!/usr/bin/env python3
"""Lifesaver Vision — ElevenLabs audio generation pipeline (Phase 6).

Generates ALL pre-cached audio for the app: lesson narration, system-safety lines,
UI/procedure sound effects and music beds, then masters them with ffmpeg and writes
Audio/ELEVENLABS_AUDIO_MANIFEST.json plus WebVTT captions per speech clip.

Security: the API key is read ONLY from the environment (ELEVENLABS_API_KEY) or the
external credential file `../../API Information/.env` relative to the project root.
The key never enters this repository, the manifest, or generated files.

Content safety: every narrated sentence is text already present in the approved course
content JSON (Resources/Courses). Blocks whose reviewStatus is not `sourceChecked`
are SKIPPED (captions-only until clinically approved). No dispatcher dialogue is
invented: only text present in course data is voiced.

Honesty: subjective voice quality requires operator listening; manifest rows carry
approvalStatus "pending_operator_listening" until a human signs off.
"""
from __future__ import annotations
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENV_FILE = os.path.join(os.path.dirname(ROOT), "..", "API Information", ".env")
AUDIO_DIR = os.path.join(ROOT, "Audio")
GEN_DIR = os.path.join(AUDIO_DIR, "Generated")
MASTER_DIR = os.path.join(AUDIO_DIR, "Mastered")
CAPTION_DIR = os.path.join(ROOT, "Resources", "Captions")
MANIFEST_PATH = os.path.join(AUDIO_DIR, "ELEVENLABS_AUDIO_MANIFEST.json")
STATE_PATH = os.path.join(GEN_DIR, ".generation_state.json")
API = "https://api.elevenlabs.io"

VOICES = {
    "narrator": {
        "voice_id": "PUGMG0tgKGWJ8f778IPo",
        "description": "Lifesaver Narrator — original ElevenLabs Voice Design creation "
                       "(Singapore English educational narrator, calm/warm/medically precise). "
                       "Selected from 3 previews on 2026-08-08; STT round-trip 100% clean, LRA 2.1 LU.",
        "model": "eleven_multilingual_v2",
        "settings": {"stability": 0.78, "similarity_boost": 0.82, "style": 0.12,
                     "use_speaker_boost": True},
    },
    "system": {
        # System safety voice: neutral, direct, never shaming (premade library voice,
        # commercially licensed via ElevenLabs subscription).
        "voice_id": "SAz9YHcvj6GT2YYXdXww",  # River — Relaxed, Neutral, Informative
        "description": "System safety voice — premade 'River' with restrained settings.",
        "model": "eleven_multilingual_v2",
        "settings": {"stability": 0.80, "similarity_boost": 0.80, "style": 0.05,
                     "use_speaker_boost": True},
    },
}

# Loudness targets (integrated LUFS / true peak dBTP)
LOUDNESS = {
    "narration": (-16.0, -1.5),
    "dialogue": (-16.0, -1.5),
    "sfx": (-18.0, -1.5),
    "music_bed": (-25.0, -2.0),
    "sting": (-20.0, -1.5),
}

SFX = [
    ("sfx.focus_confirm", "Short, clean medical-training focus confirmation tone, warm glass-like transient, subtle spatial tail, reassuring rather than playful, no alarm character, approximately 0.7 seconds, suitable for Apple Vision Pro educational UI.", 0.7, 0.6, False),
    ("sfx.pinch_confirm", "Soft tactile pinch confirmation blip, gentle rounded transient, warm and precise, calm educational interface, approximately 0.5 seconds.", 0.5, 0.6, False),
    ("sfx.answer_correct", "Gentle affirmative two-note chime, warm marimba-like timbre, encouraging and calm, medical education context, approximately 1 second, no arcade character.", 1.0, 0.55, False),
    ("sfx.answer_incorrect", "Soft low neutral tone indicating an incorrect answer, kind and non-punitive, single muted note with short decay, approximately 0.8 seconds, never harsh.", 0.8, 0.55, False),
    ("sfx.safety_warning", "Clear but calm safety-critical alert: two firm mid-frequency tones, serious and attention-getting without panic or klaxon character, approximately 1.2 seconds, medical training context.", 1.2, 0.6, False),
    ("sfx.module_complete", "Warm resolved completion chime sequence, three ascending soft notes with gentle shimmer, professional and restrained, approximately 2 seconds.", 2.0, 0.55, False),
    ("sfx.badge_unlocked", "Bright but gentle achievement sparkle with a soft bell core, brief shimmering tail, celebratory yet calm, approximately 1.5 seconds.", 1.5, 0.55, False),
    ("sfx.aed_case_open", "Foley of a rigid plastic medical case unlatching and opening, two firm clicks then a hinge swing, realistic and clean, approximately 1.5 seconds.", 1.5, 0.5, False),
    ("sfx.electrode_packet_open", "Foley of a foil electrode packet being torn open, crisp short tear with slight crinkle, realistic medical training sound, approximately 1.2 seconds.", 1.2, 0.5, False),
    ("sfx.pad_backing_peel", "Foley of an adhesive pad backing being peeled away, smooth sticky peel, approximately 1.2 seconds, clean and close-mic'd.", 1.2, 0.5, False),
    ("sfx.connector_insert", "Foley of a small medical cable connector clicking firmly into a socket, single positive click with slight plastic resonance, approximately 0.6 seconds.", 0.6, 0.55, False),
    ("sfx.aed_analysis", "Abstract training-device analysis loop: soft rhythmic electronic ticking with a gentle rising interest, clearly synthetic and generic, NOT imitating any commercial defibrillator sound, approximately 4 seconds.", 4.0, 0.45, False),
    ("sfx.aed_charging", "Abstract training-device charging ramp: smooth rising synthetic tone, restrained and serious, clearly generic training audio not imitating any commercial defibrillator, approximately 3 seconds.", 3.0, 0.45, False),
    ("sfx.clear_cue", "Distinct spatial 'stand clear' cue: firm single broadband pulse with short authoritative tail, serious but not frightening, approximately 1 second.", 1.0, 0.55, False),
    ("sfx.metronome", "Single clean compression-tempo metronome tick, woodblock-like with soft body, precise transient for rhythm keeping, a single very short tick then silence, half a second total.", 0.5, 0.65, False),
    ("sfx.paramedic_arrival", "Approaching footsteps of two people with soft equipment-bag rustle and a calm door opening, no sirens, realistic room ambience, approximately 4 seconds.", 4.0, 0.4, False),
    ("sfx.debrief_transition", "Calm scene-transition whoosh into stillness, soft airy sweep with warm settle, approximately 2 seconds, contemplative educational atmosphere.", 2.0, 0.45, False),
]

MUSIC = [
    ("music.academy_hub", "Calm, optimistic spatial-learning ambience, warm marimba, soft piano, subtle organic percussion and airy synthesiser, approximately 72 BPM, instrumental, no vocals, no dramatic trailer elements, seamless loop, professional medical education atmosphere.", 120),
    ("music.anatomy_lesson", "Gentle scientific discovery underscore, soft pulsing synth, mallet texture, light strings, 68 BPM, curious and reassuring, instrumental, no vocals, minimal low-frequency energy, designed to sit beneath narration.", 120),
    ("music.scenario_bed", "Restrained emergency-training underscore, subtle pulse beginning near 68 BPM and gradually rising toward 86 BPM, no sirens, no alarm imitation, no horror, no aggressive percussion, calm focus rather than panic, instrumental.", 150),
    ("music.completion_sting", "Brief hopeful educational achievement sting, warm piano and soft strings, confident but restrained, approximately eight seconds, no vocals.", 8),
]


def log(msg: str) -> None:
    print(f"[audio] {msg}", flush=True)


def load_key() -> str:
    key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    if not key and os.path.exists(ENV_FILE):
        for line in open(ENV_FILE, encoding="utf-8"):
            m = re.match(r"\s*ELEVENLABS_API_KEY\s*=\s*(\S+)", line)
            if m:
                key = m.group(1).strip().strip('"').strip("'")
                break
    if not key:
        sys.exit("ERROR: ELEVENLABS_API_KEY not found in env or credential file")
    return key


def api_request(key: str, path: str, payload: dict | None = None, query: str = "",
                retries: int = 4) -> bytes:
    url = f"{API}{path}{query}"
    data = json.dumps(payload).encode() if payload is not None else None
    for attempt in range(retries):
        req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
        req.add_header("xi-api-key", key)
        if data:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            body = e.read()[:400]
            if e.code in (429, 500, 502, 503) and attempt < retries - 1:
                wait = 2 ** (attempt + 2)
                log(f"HTTP {e.code} on {path}; retry in {wait}s ({body[:120]!r})")
                time.sleep(wait)
                continue
            raise RuntimeError(f"HTTP {e.code} on {path}: {body!r}") from e
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < retries - 1:
                time.sleep(2 ** (attempt + 2))
                continue
            raise
    raise RuntimeError("unreachable")


def pcm_to_wav(pcm_path: str, wav_path: str, rate: int = 44100, channels: int = 1) -> None:
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "s16le", "-ar", str(rate),
                    "-ac", str(channels), "-i", pcm_path, wav_path], check=True)


def measure(path: str) -> dict:
    dur = subprocess.run(["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
                          "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip()
    out = subprocess.run(["ffmpeg", "-i", path, "-af", "ebur128=framelog=quiet", "-f",
                          "null", "-"], capture_output=True, text=True).stderr
    lufs = None
    m = re.search(r"I:\s*(-?[\d.]+)\s*LUFS", out)
    if m:
        lufs = float(m.group(1))
    return {"durationSeconds": round(float(dur or 0), 3), "integratedLUFS": lufs}


def master(src_wav: str, dst_wav: str, target_lufs: float, true_peak: float) -> None:
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", src_wav, "-af",
                    f"loudnorm=I={target_lufs}:TP={true_peak}:LRA=11", "-ar", "48000",
                    dst_wav], check=True)


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_vtt(caption_path: str, text: str, duration: float) -> None:
    def ts(t: float) -> str:
        ms = int(round(t * 1000))
        return f"{ms // 3600000:02d}:{ms % 3600000 // 60000:02d}:{ms % 60000 // 1000:02d}.{ms % 1000:03d}"
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", text.strip()) if s.strip()]
    if not sentences:
        sentences = [text.strip()]
    total_chars = sum(len(s) for s in sentences) or 1
    lines = ["WEBVTT", ""]
    t = 0.0
    for s in sentences:
        seg = duration * len(s) / total_chars
        lines += [f"{ts(t)} --> {ts(min(t + seg, duration))}", s, ""]
        t += seg
    os.makedirs(os.path.dirname(caption_path), exist_ok=True)
    open(caption_path, "w", encoding="utf-8").write("\n".join(lines))


def collect_speech_units() -> list[dict]:
    """Narration/dialogue units — text taken VERBATIM from approved course data only."""
    units: list[dict] = []
    course = json.load(open(os.path.join(ROOT, "Resources", "Courses", "course_v1.json"),
                            encoding="utf-8"))
    course = course.get("course", course)
    for mod in course.get("modules", []):
        mid = mod.get("id", "M?")
        if mod.get("reviewStatus") == "sourceChecked" and mod.get("summary"):
            units.append({"id": f"nar.{mid}.intro", "role": "narrator", "kind": "narration",
                          "purpose": f"Module {mid} introduction", "text": f"{mod.get('title', '')}. {mod['summary']}"})
        for les in mod.get("lessons", []):
            for blk in les.get("contentBlocks", []):
                if blk.get("kind") != "text":
                    continue
                if blk.get("reviewStatus") != "sourceChecked":
                    log(f"skip narration (reviewStatus={blk.get('reviewStatus')}): {blk.get('id')}")
                    continue
                text = f"{blk.get('title', '').rstrip('.')}. {blk.get('body', '').strip()}"
                units.append({"id": f"nar.{blk['id']}", "role": "narrator", "kind": "narration",
                              "purpose": f"Lesson narration for content block {blk['id']}",
                              "text": text})
    scen_path = os.path.join(ROOT, "Resources", "Courses", "scenarios_v1.json")
    if os.path.exists(scen_path):
        scen = json.load(open(scen_path, encoding="utf-8"))
        seen: set[str] = set()
        for sc in scen.get("scenarios", []):
            for fb in sc.get("feedbackStatements", []):
                text = (fb.get("text") or fb.get("statement") or "").strip()
                fid = fb.get("id") or hashlib.sha256(text.encode()).hexdigest()[:10]
                if not text or fid in seen:
                    continue
                seen.add(fid)
                units.append({"id": f"sys.{fid}", "role": "system", "kind": "dialogue",
                              "purpose": f"Safety feedback ({sc.get('id', '?')})", "text": text})
    return units


def main() -> None:
    key = load_key()
    for d in (GEN_DIR, MASTER_DIR, CAPTION_DIR):
        os.makedirs(d, exist_ok=True)
    state = json.load(open(STATE_PATH)) if os.path.exists(STATE_PATH) else {}
    manifest = {"generatedWith": "Scripts/ElevenLabs/generate_audio.py",
                "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "licence": "ElevenLabs paid-subscription commercial licence",
                "assets": []}

    units = collect_speech_units()
    log(f"{len(units)} speech units, {len(SFX)} sfx, {len(MUSIC)} music tracks")
    total_chars = sum(len(u["text"]) for u in units)
    log(f"speech characters to synthesise: {total_chars}")

    for u in units:
        voice = VOICES[u["role"]]
        content_hash = hashlib.sha256((u["text"] + json.dumps(voice, sort_keys=True)).encode()).hexdigest()
        raw = os.path.join(GEN_DIR, u["kind"], f"{u['id']}.wav")
        if state.get(u["id"]) == content_hash and os.path.exists(raw):
            log(f"cached: {u['id']}")
        else:
            os.makedirs(os.path.dirname(raw), exist_ok=True)
            pcm = api_request(key, f"/v1/text-to-speech/{voice['voice_id']}",
                              {"text": u["text"], "model_id": voice["model"],
                               "voice_settings": voice["settings"]},
                              query="?output_format=pcm_44100")
            tmp = raw + ".pcm"
            open(tmp, "wb").write(pcm)
            pcm_to_wav(tmp, raw)
            os.remove(tmp)
            state[u["id"]] = content_hash
            json.dump(state, open(STATE_PATH, "w"))
            log(f"generated: {u['id']} ({len(u['text'])} chars)")
            time.sleep(0.4)
        target, tp = LOUDNESS[u["kind"]]
        mastered = os.path.join(MASTER_DIR, u["kind"], f"{u['id']}.wav")
        os.makedirs(os.path.dirname(mastered), exist_ok=True)
        master(raw, mastered, target, tp)
        meta = measure(mastered)
        caption = os.path.join(CAPTION_DIR, f"{u['id']}.vtt")
        write_vtt(caption, u["text"], meta["durationSeconds"] or 1.0)
        manifest["assets"].append({
            "assetID": u["id"], "filename": os.path.relpath(mastered, ROOT),
            "purpose": u["purpose"], "prompt": u["text"],
            "voiceID": voice["voice_id"], "voiceDescription": voice["description"],
            "model": voice["model"], "settings": voice["settings"], "seed": None,
            "outputFormat": "wav (mastered from pcm_44100; 48 kHz mono master)",
            "sampleRate": 48000, **meta,
            "generationDate": time.strftime("%Y-%m-%d"),
            "reviewer": None, "approvalStatus": "pending_operator_listening",
            "sha256": sha256(mastered),
            "licenceNote": "Generated with ElevenLabs under active paid subscription; original voice design, no cloning of real persons.",
            "captionFile": os.path.relpath(caption, ROOT),
            "localisationStatus": "en-SG v1 only; architecture localisation-ready"})

    for sid, prompt, dur, influence, loop in SFX:
        content_hash = hashlib.sha256(f"{prompt}|{dur}|{influence}".encode()).hexdigest()
        raw = os.path.join(GEN_DIR, "sfx", f"{sid}.wav")
        if state.get(sid) == content_hash and os.path.exists(raw):
            log(f"cached: {sid}")
        else:
            os.makedirs(os.path.dirname(raw), exist_ok=True)
            try:
                audio = api_request(key, "/v1/sound-generation",
                                    {"text": prompt, "duration_seconds": dur,
                                     "prompt_influence": influence,
                                     "model_id": "eleven_text_to_sound_v2",
                                     "loop": loop}, query="?output_format=pcm_44100")
            except RuntimeError as e:
                log(f"sound model fallback for {sid}: {e}")
                audio = api_request(key, "/v1/sound-generation",
                                    {"text": prompt, "duration_seconds": dur,
                                     "prompt_influence": influence, "loop": loop},
                                    query="?output_format=pcm_44100")
            tmp = raw + ".pcm"
            open(tmp, "wb").write(audio)
            pcm_to_wav(tmp, raw)
            os.remove(tmp)
            state[sid] = content_hash
            json.dump(state, open(STATE_PATH, "w"))
            log(f"generated: {sid}")
            time.sleep(0.4)
        target, tp = LOUDNESS["sfx"]
        mastered = os.path.join(MASTER_DIR, "sfx", f"{sid}.wav")
        os.makedirs(os.path.dirname(mastered), exist_ok=True)
        master(raw, mastered, target, tp)
        meta = measure(mastered)
        manifest["assets"].append({
            "assetID": sid, "filename": os.path.relpath(mastered, ROOT),
            "purpose": "UI / procedure sound effect", "prompt": prompt,
            "voiceID": None, "voiceDescription": None,
            "model": "eleven_text_to_sound_v2 (with API-default fallback)",
            "settings": {"promptInfluence": influence, "durationSeconds": dur, "loop": loop},
            "seed": None, "outputFormat": "wav (mastered; 48 kHz)", "sampleRate": 48000,
            **meta, "generationDate": time.strftime("%Y-%m-%d"), "reviewer": None,
            "approvalStatus": "pending_operator_listening", "sha256": sha256(mastered),
            "licenceNote": "Original generated SFX; no commercial AED sound sequence imitated.",
            "captionFile": None, "localisationStatus": "n/a"})

    for mid, prompt, dur in MUSIC:
        content_hash = hashlib.sha256(f"{prompt}|{dur}".encode()).hexdigest()
        raw = os.path.join(GEN_DIR, "music", f"{mid}.wav")
        if state.get(mid) == content_hash and os.path.exists(raw):
            log(f"cached: {mid}")
        else:
            os.makedirs(os.path.dirname(raw), exist_ok=True)
            audio = api_request(key, "/v1/music",
                                {"prompt": prompt, "music_length_ms": dur * 1000},
                                query="?output_format=pcm_44100")
            tmp = raw + ".pcm"
            open(tmp, "wb").write(audio)
            pcm_to_wav(tmp, raw, channels=2)
            os.remove(tmp)
            state[mid] = content_hash
            json.dump(state, open(STATE_PATH, "w"))
            log(f"generated: {mid} ({dur}s)")
            time.sleep(1.0)
        kind = "sting" if mid.endswith("sting") else "music_bed"
        target, tp = LOUDNESS[kind]
        mastered = os.path.join(MASTER_DIR, "music", f"{mid}.wav")
        os.makedirs(os.path.dirname(mastered), exist_ok=True)
        master(raw, mastered, target, tp)
        meta = measure(mastered)
        manifest["assets"].append({
            "assetID": mid, "filename": os.path.relpath(mastered, ROOT),
            "purpose": "Instrumental music" + (" sting" if kind == "sting" else " bed"),
            "prompt": prompt, "voiceID": None, "voiceDescription": None,
            "model": "eleven /v1/music (account's current music model)",
            "settings": {"lengthSeconds": dur}, "seed": None,
            "outputFormat": "wav stereo (mastered; 48 kHz)", "sampleRate": 48000,
            **meta, "generationDate": time.strftime("%Y-%m-%d"), "reviewer": None,
            "approvalStatus": "pending_operator_listening", "sha256": sha256(mastered),
            "licenceNote": "Original instrumental composition via ElevenLabs Music.",
            "captionFile": None, "localisationStatus": "n/a"})

    json.dump(manifest, open(MANIFEST_PATH, "w", encoding="utf-8"), indent=1)
    log(f"manifest written: {MANIFEST_PATH} ({len(manifest['assets'])} assets)")


if __name__ == "__main__":
    main()
