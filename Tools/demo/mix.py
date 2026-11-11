"""Mixes the voiceover into the recorded demo and writes subtitles.

usage: mix.py <raw.mov> <trace.txt> <rec.log> <vo folder> <out.mp4>

The trace has `scene <n> <host seconds> <length>` for each line; rec.log has the host time of
the first recorded frame (`first <seconds>`). Each NN.wav goes in at its scene's time.
"""
import json, os, re, subprocess, sys

raw, trace, reclog, vo, out = sys.argv[1:6]
first = float(re.search(r"first ([\d.]+)", open(reclog).read()).group(1))
scenes = []
for line in open(trace):
    m = re.match(r"scene (\d+) ([\d.]+)", line)
    if m:
        scenes.append((int(m.group(1)), float(m.group(2)) - first))

def words(n):
    d = json.load(open(os.path.join(vo, f"{n:02d}.json")))
    out, cur, start, end = [], "", 0.0, 0.0
    for c, s, e in zip(d["characters"], d["character_start_times_seconds"], d["character_end_times_seconds"]):
        if c in " \n":
            if cur: out.append((cur, start, end))
            cur = ""
        else:
            if not cur: start = s
            cur += c; end = e
    if cur: out.append((cur, start, end))
    return out

def chunks(ws):
    # Same rule as DemoStage.chunks.
    res, cur = [], []
    def flush():
        if cur: res.append([cur[0][1], cur[-1][2], " ".join(w[0] for w in cur)])
    for w in ws:
        cur.append(w)
        length = sum(len(x[0]) for x in cur) + len(cur)
        ends = w[0][-1] in ".?!…:"; pause = w[0][-1] in ",;"
        if (ends and length > 14) or (pause and length > 34) or length > 52:
            flush(); cur = []
    flush()
    for i in range(len(res) - 1): res[i][1] = res[i + 1][0]
    if res: res[-1][1] += 0.5
    return res

def stamp(t):
    ms = int(round(t * 1000)); h, ms = divmod(ms, 3600000); m, ms = divmod(ms, 60000); s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

srt, k = [], 1
inputs, filters, labels = ["-i", raw], [], []
for i, (n, t) in enumerate(scenes):
    wav = os.path.join(vo, f"{n:02d}.wav")
    if not os.path.exists(wav): continue
    inputs += ["-i", wav]
    ms = max(0, int(round(t * 1000)))
    filters.append(f"[{len(labels) + 1}:a]adelay={ms}|{ms}[a{len(labels)}]")
    labels.append(f"[a{len(labels)}]")
    for s, e, text in chunks(words(n)):
        srt.append(f"{k}\n{stamp(t + s)} --> {stamp(t + e)}\n{text}\n"); k += 1
filters.append("".join(labels) + f"amix=inputs={len(labels)}:normalize=0,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000,apad[aout]")
filters.append("[0:v]fps=60,scale=1920:1080:flags=lanczos,format=yuv420p[vout]")
cmd = ["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", ";".join(filters),
       "-map", "[vout]", "-map", "[aout]", "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-profile:v", "high",
       "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-shortest", out]
subprocess.run(cmd, check=True)
open(os.path.splitext(out)[0] + ".srt", "w").write("\n".join(srt))
print("wrote", out, "with", len(labels), "voiceover lines; offsets", [(n, round(t, 2)) for n, t in scenes])
