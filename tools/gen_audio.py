"""Generates every sound in res://audio procedurally (no samples needed).

    python tools/gen_audio.py          (needs numpy, scipy, and ffmpeg for the .ogg loops)

Short effects are written as .wav, loops and music as .ogg. Each loop is
rendered so its tail wraps around to its start: they loop without a seam.
Swap any file for a real recording with the same name and the game uses it.
"""
import os
import subprocess
import numpy as np
from scipy import signal
from scipy.io import wavfile

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "audio")
rng = np.random.default_rng(7)


# --- Building blocks ---------------------------------------------------------

def t_axis(dur):
    return np.arange(int(dur * SR)) / SR


def noise(dur):
    return rng.uniform(-1, 1, int(dur * SR))


def brown(dur):
    x = np.cumsum(rng.normal(0, 1, int(dur * SR)))
    x = signal.sosfilt(signal.butter(1, 20, "hp", fs=SR, output="sos"), x)
    return x / (np.abs(x).max() + 1e-9)


def filt(x, kind, f, order=2):
    return signal.sosfilt(signal.butter(order, f, kind, fs=SR, output="sos"), x)


def env_exp(dur, decay):
    return np.exp(-t_axis(dur) / decay)


def adsr(dur, a=0.01, d=0.1, s=0.7, r=0.2):
    n = int(dur * SR)
    e = np.full(n, s)
    na, nd, nr = int(a * SR), int(d * SR), int(r * SR)
    e[:na] = np.linspace(0, 1, na)
    e[na:na + nd] = np.linspace(1, s, len(e[na:na + nd]))
    if nr > 0:
        e[-nr:] *= np.linspace(1, 0, nr)
    return e


def saw(freq, dur, vib_rate=0.0, vib_depth=0.0, glide=None):
    t = t_axis(dur)
    f = np.full_like(t, freq) if glide is None else np.interp(t, glide[0], glide[1])
    f = f * (1 + vib_depth * np.sin(2 * np.pi * vib_rate * t))
    phase = np.cumsum(f) / SR
    return 2 * (phase % 1.0) - 1


def place(buf, x, at):
    i = int(at * SR)
    if i >= len(buf):
        return
    n = min(len(x), len(buf) - i)
    buf[i:i + n] += x[:n]


def reverb(x, size=1.2, mix=0.25):
    ir = noise(size) * env_exp(size, size / 6)
    ir = filt(ir, "lowpass", 5000)
    wet = signal.fftconvolve(x, ir)[: len(x)]
    wet /= np.abs(wet).max() + 1e-9
    return (1 - mix) * x + mix * wet * np.abs(x).max()


def norm(x, peak=0.89):
    return x / (np.abs(x).max() + 1e-9) * peak


def fade(x, fin=0.002, fout=0.01):
    a, b = int(fin * SR), int(fout * SR)
    if a:
        x[:a] *= np.linspace(0, 1, a)
    if b:
        x[-b:] *= np.linspace(1, 0, b)
    return x


def write_wav(name, x, peak=0.89):
    x = fade(norm(x, peak))
    wavfile.write(os.path.join(OUT, name + ".wav"), SR, (x * 32767).astype(np.int16))


def write_ogg(name, x, peak=0.7):
    x = norm(x, peak)
    tmp = os.path.join(OUT, name + "_tmp.wav")
    wavfile.write(tmp, SR, (x * 32767).astype(np.int16))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", tmp, "-c:a", "libvorbis", "-q:a", "4",
                    os.path.join(OUT, name + ".ogg")], check=True)
    os.remove(tmp)


def loop_wrap(x, length):
    """Fold everything past `length` back onto the start: a seamless loop."""
    n = int(length * SR)
    out = x[:n].copy()
    tail = x[n:]
    while len(tail):
        k = min(len(tail), n)
        out[:k] += tail[:k]
        tail = tail[k:]
    return out


# --- Instruments --------------------------------------------------------------

def horn(freq, dur, glide=None, bright=1800):
    """A war horn: a buzzy saw through a soft, slowly opening filter."""
    x = saw(freq, dur, vib_rate=5.0, vib_depth=0.006, glide=glide) + 0.5 * saw(freq * 1.003, dur, glide=glide)
    x = filt(x, "lowpass", bright, 2) * adsr(dur, a=0.08, d=0.2, s=0.8, r=min(0.35, dur * 0.4))
    breath = filt(noise(dur), "bandpass", [400, 1500]) * adsr(dur, 0.05, 0.1, 0.15, 0.2) * 0.15
    return x + breath


def drum(freq=110, dur=0.5, drop=2.2, snap=0.3):
    t = t_axis(dur)
    f = freq * (1 + (drop - 1) * np.exp(-t / 0.03))
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * env_exp(dur, dur / 4)
    hit = filt(noise(dur), "lowpass", 1500) * env_exp(dur, 0.02) * snap
    return body + hit


def clang(f0=None, dur=0.4):
    f0 = f0 or rng.uniform(900, 1700)
    t = t_axis(dur)
    x = np.zeros_like(t)
    for ratio, amp, dec in [(1.0, 1.0, 0.18), (2.76, 0.6, 0.12), (5.40, 0.35, 0.08), (8.93, 0.2, 0.05), (1.49, 0.3, 0.1)]:
        x += amp * np.sin(2 * np.pi * f0 * ratio * t + rng.uniform(0, 6)) * np.exp(-t / (dec * rng.uniform(0.7, 1.3)))
    click = filt(noise(dur), "highpass", 2500) * env_exp(dur, 0.006) * 1.2
    thud = filt(noise(dur), "lowpass", 400) * env_exp(dur, 0.04) * 0.6
    return x + click + thud


def bell(f=620, dur=2.5):
    t = t_axis(dur)
    x = np.zeros_like(t)
    for ratio, amp in [(0.56, 0.6), (0.92, 0.5), (1.19, 1.0), (1.71, 0.5), (2.0, 0.4), (2.74, 0.35), (3.0, 0.25), (3.76, 0.2), (4.07, 0.15)]:
        x += amp * np.sin(2 * np.pi * f * ratio * t) * np.exp(-t / (dur / (1 + ratio)))
    return x


def pluck(freq, dur=1.6, damp=0.996):
    """Karplus-Strong: a lute-ish plucked string."""
    n = int(dur * SR)
    period = int(SR / freq)
    buf = rng.uniform(-1, 1, period)
    buf = filt(buf, "lowpass", 3000, 1)
    out = np.zeros(n)
    for i in range(n):
        out[i] = buf[i % period]
        buf[i % period] = damp * 0.5 * (buf[i % period] + buf[(i + 1) % period])
    return out


def pad(freqs, dur):
    x = np.zeros(int(dur * SR))
    for f in freqs:
        for det in (0.997, 1.0, 1.004):
            x += saw(f * det, dur)
    x = filt(x, "lowpass", 900, 2)
    return x * adsr(dur, a=dur * 0.3, d=0.1, s=1.0, r=dur * 0.35) / (len(freqs) * 3)


def note(name):
    names = {"C": -9, "C#": -8, "D": -7, "Eb": -6, "E": -5, "F": -4, "F#": -3, "G": -2, "Ab": -1, "A": 0, "Bb": 1, "B": 2}
    return 440.0 * 2 ** ((names[name[:-1]] + 12 * (int(name[-1]) - 4)) / 12)


# --- Effects ------------------------------------------------------------------

def make_sfx():
    # UI
    d = 0.06
    write_wav("ui_click", np.sin(2 * np.pi * 1800 * t_axis(d)) * env_exp(d, 0.008) * 0.6
              + filt(noise(d), "bandpass", [2000, 6000]) * env_exp(d, 0.004) * 0.5, 0.5)
    d = 0.14
    write_wav("ui_select", (np.sin(2 * np.pi * 520 * t_axis(d)) + 0.3 * np.sin(2 * np.pi * 1040 * t_axis(d)))
              * env_exp(d, 0.035), 0.5)
    coin = np.zeros(int(0.45 * SR))
    for at, f in [(0.0, 2300), (0.07, 3100)]:
        tt = t_axis(0.35)
        ping = sum(a * np.sin(2 * np.pi * f * r * tt) * np.exp(-tt / dd) for r, a, dd in [(1, 1, 0.12), (2.4, 0.4, 0.06), (3.9, 0.2, 0.03)])
        place(coin, ping, at)
    write_wav("coin", coin, 0.5)

    # Orders and signals
    write_wav("order", drum(150, 0.35, 1.8, 0.4) + 0.5 * np.pad(drum(190, 0.3, 1.6, 0.3), (int(0.11 * SR), 0))[: int(0.35 * SR)], 0.7)
    write_wav("signal", reverb(horn(note("A3"), 0.7), 1.0, 0.3), 0.8)
    start = np.zeros(int(4.2 * SR))
    place(start, horn(note("D3"), 1.3), 0.0)
    place(start, horn(note("A3"), 1.9), 1.15)
    for at in (0.0, 1.15, 2.2, 2.55):
        place(start, drum(70, 1.0, 2.5, 0.5) * 0.9, at)
    write_wav("battle_start", reverb(start, 1.6, 0.35), 0.85)
    write_wav("rout", reverb(horn(note("A3"), 1.1, glide=([0, 0.3, 1.1], [note("A3"), note("A3"), note("D3")]), bright=1200), 1.2, 0.3), 0.7)
    rally = np.zeros(int(1.4 * SR))
    for i, n in enumerate(["D4", "F#4", "A4"]):
        place(rally, horn(note(n), 0.45 if i < 2 else 0.8, bright=2400), i * 0.18)
    write_wav("rally", reverb(rally, 1.0, 0.3), 0.7)

    # Melee
    for i in range(4):
        write_wav("clash%d" % (i + 1), clang(dur=0.45), 0.8)
    for i in range(3):
        d = 0.35
        tt = t_axis(d)
        body = np.sin(2 * np.pi * np.cumsum(90 * (1 + np.exp(-tt / 0.02))) / SR) * env_exp(d, 0.06)
        cloth = filt(noise(d), "bandpass", [200, 1200]) * env_exp(d, 0.05) * rng.uniform(0.6, 1.0)
        write_wav("hit%d" % (i + 1), body + cloth, 0.75)

    # Village
    alarm = np.zeros(int(3.0 * SR))
    for k in range(3):
        place(alarm, bell(640, 2.2), k * 0.42)
    write_wav("bell", reverb(alarm, 1.2, 0.25), 0.7)
    d = 2.0
    whoosh = filt(noise(d), "lowpass", 900) * adsr(d, a=0.5, d=0.2, s=0.8, r=1.0)
    crash = filt(noise(d), "lowpass", 250) * env_exp(d, 0.4)
    burned = np.zeros(int(2.6 * SR))
    place(burned, whoosh, 0.0)
    place(burned, crash * 1.5, 0.55)
    place(burned, drum(55, 1.5, 2.0, 0.2), 0.55)
    write_wav("burned", reverb(burned, 1.2, 0.25), 0.8)

    # Intel
    d = 0.45
    sweep = filt(noise(d), "bandpass", [800, 5000]) * np.sin(np.pi * t_axis(d) / d) ** 2
    write_wav("scout", sweep, 0.45)

    # Endings
    fan = np.zeros(int(4.5 * SR))
    for i, n in enumerate(["D4", "F#4", "A4"]):
        place(fan, horn(note(n), 0.32, bright=2600), i * 0.22)
    for n in ["D4", "F#4", "A4", "D5"]:
        place(fan, horn(note(n), 2.4, bright=2600) * 0.6, 0.7)
    for at in (0.0, 0.22, 0.44, 0.7):
        place(fan, drum(80, 1.2, 2.2, 0.4) * 0.8, at)
    write_wav("victory", reverb(fan, 1.8, 0.35), 0.85)
    dirge = np.zeros(int(5.5 * SR))
    for i, n in enumerate(["D3", "C3", "Bb2", "A2"]):
        place(dirge, horn(note(n), 1.6 if i < 3 else 2.6, bright=900), i * 1.0)
    place(dirge, drum(55, 2.0, 1.8, 0.1), 3.0)
    write_wav("defeat", reverb(dirge, 2.0, 0.4), 0.75)


# --- Loops --------------------------------------------------------------------

def make_loops():
    # Wind over open ground, the odd bird
    L = 30.0
    total = L + 3.0
    wind = filt(brown(total), "lowpass", 600) * 0.7
    gust = 0.6 + 0.4 * np.sin(2 * np.pi * t_axis(total) / 11.0) * np.sin(2 * np.pi * t_axis(total) / 7.3)
    field = wind * gust + filt(noise(total), "bandpass", [1500, 4000]) * 0.03 * gust
    for _ in range(9):
        at = rng.uniform(0, L)
        f = rng.uniform(2500, 4200)
        for k in range(rng.integers(2, 5)):
            d = 0.09
            tt = t_axis(d)
            chirp = np.sin(2 * np.pi * np.cumsum(f * (1 + 0.25 * np.sin(np.pi * tt / d))) / SR) * np.sin(np.pi * tt / d) ** 2
            place(field, chirp * 0.07, at + k * 0.13)
    write_ogg("amb_field", loop_wrap(field, L), 0.6)

    # Melee din: a roar of voices and steel
    L = 12.0
    total = L + 1.5
    roar = filt(noise(total), "bandpass", [250, 1400], 2)
    roar *= 0.55 + 0.45 * np.abs(np.sin(2 * np.pi * t_axis(total) * 0.37)) * np.abs(np.sin(2 * np.pi * t_axis(total) * 0.23 + 1))
    din = roar * 0.5
    for _ in range(70):
        place(din, clang(dur=0.35) * rng.uniform(0.08, 0.25), rng.uniform(0, L))
    for _ in range(25):
        place(din, filt(noise(0.2), "lowpass", 300) * env_exp(0.2, 0.04) * 0.4, rng.uniform(0, L))
    write_ogg("battle_din", loop_wrap(reverb(din, 0.8, 0.3), L), 0.7)

    # Fire: low rumble and crackle
    L = 8.0
    total = L + 0.5
    fire = filt(brown(total), "lowpass", 300) * 0.6
    for _ in range(260):
        d = rng.uniform(0.003, 0.02)
        place(fire, filt(noise(d), "highpass", 1500) * rng.uniform(0.1, 0.6), rng.uniform(0, L))
    write_ogg("fire", loop_wrap(fire, L), 0.6)


# --- Music --------------------------------------------------------------------

def make_music():
    # Camp: a lute over a soft pad, D minor (i - VI - III - VII), 32 s
    bar = 4.0
    prog = [["D3", "F3", "A3"], ["Bb2", "D3", "F3"], ["F3", "A3", "C4"], ["C3", "E3", "G3"]] * 2
    L = bar * len(prog)
    m = np.zeros(int((L + 4) * SR))
    for i, chord in enumerate(prog):
        place(m, pad([note(n) for n in chord], bar + 1.0) * 0.5, i * bar)
        place(m, np.sin(2 * np.pi * note(chord[0]) / 2 * t_axis(bar)) * adsr(bar, 0.4, 0.1, 0.8, 0.6) * 0.18, i * bar)
        arp = [chord[0], chord[1], chord[2], chord[1]] * 2
        for k, n in enumerate(arp):
            up = n[:-1] + str(int(n[-1]) + 1)
            if k in (0, 3, 4, 6):
                place(m, pluck(note(up), 1.6) * (0.35 if k else 0.45), i * bar + k * bar / 8)
    write_ogg("music_camp", loop_wrap(reverb(m, 2.0, 0.3), L), 0.55)

    # Planning: tense and sparse. A drone, a slow ostinato, distant drums. 24 s
    L = 24.0
    m = np.zeros(int((L + 4) * SR))
    t = t_axis(L + 4)
    drone = sum(np.sin(2 * np.pi * f * t) * a for f, a in [(note("D2"), 0.5), (note("A2"), 0.25), (note("D3"), 0.12)])
    m += drone * (0.7 + 0.3 * np.sin(2 * np.pi * t / 12.0)) * 0.35
    ost = ["D4", "A3", "F4", "E4"]
    for k in range(16):
        place(m, pluck(note(ost[k % 4]), 2.2, 0.997) * 0.3, k * 1.5)
    for k in range(6):
        place(m, drum(65, 1.5, 1.6, 0.05) * 0.35, k * 4.0)
        place(m, drum(65, 1.5, 1.6, 0.05) * 0.2, k * 4.0 + 0.5)
    write_ogg("music_plan", loop_wrap(reverb(m, 2.2, 0.35), L), 0.5)

    # Battle: war drums, a low drone and horn swells. 120 bpm, 16 s
    beat = 0.5
    L = 16.0
    m = np.zeros(int((L + 3) * SR))
    t = t_axis(L + 3)
    m += np.sin(2 * np.pi * note("D2") * t) * 0.18 + saw(note("D2"), L + 3) * 0.03
    pattern = [1, 0, 0.5, 0, 1, 0, 0.5, 0.5]  # per eighth
    eighth = beat / 2
    for i in range(int(L / eighth)):
        v = pattern[i % len(pattern)]
        if v:
            place(m, drum(62 if v == 1 else 95, 0.8, 2.3, 0.35) * v * 0.9, i * eighth)
        if i % 4 == 2:
            place(m, filt(noise(0.08), "bandpass", [1500, 5000]) * env_exp(0.08, 0.015) * 0.25, i * eighth)
    for at, n in [(0.0, "D3"), (4.0, "F3"), (8.0, "D3"), (12.0, "C3")]:
        place(m, horn(note(n), 3.2, bright=1100) * 0.3, at)
    write_ogg("music_battle", loop_wrap(reverb(m, 1.4, 0.25), L), 0.6)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    make_sfx()
    make_loops()
    make_music()
    print("wrote", len(os.listdir(OUT)), "files to", OUT)
