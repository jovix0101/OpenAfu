#!/usr/bin/env python3
"""icomon 27 / AFU-WL 合成帧解码器（无任何真实测量数据）。

用法：
    python3 samples/decode.py                 # 自检内置合成帧
    python3 samples/decode.py <file>         # 逐行读 hex 帧（空行 / # 注释跳过）

每行形如：  ac 29 80 09 32 40 ... d5 a4
只看 20 字节定长帧。校验和 = sum(b[2..18]) & 0x1F，与末字节低 5 位比较。
"""

from __future__ import annotations

import sys
from pathlib import Path

# 全仓库统一的合成演示人设（见 docs/07-privacy.md）
DEMO_H_CM = 175.0
DEMO_K = 0.9788
DEMO_W = 78.40
DEMO_Z = (505, 514)

FRAMES: dict[str, str] = {
    "weight  (0xD5 78.40 kg, state=1)":
        "ac 29 80 09 32 40 02 00 05 40 00 64 00 00 00 00 00 29 d5 a4",
    "adc     (0xD6 Z=500/514 Ω)":
        "ac 29 02 00 01 f4 02 02 01 80 09 32 40 00 00 00 00 29 d6 f6",
    "history (0xD8 offline record)":
        "ac 29 01 68 f2 a1 c4 80 09 32 40 00 00 00 00 00 00 29 d8 bc",
    "write: user info (imp=1, 175cm/42y/male/78.40kg)":
        "ac 27 82 97 ec 6a 20 00 01 af a0 1e 2a 01 a0 1e 01 00 d0 b7",
    "write: set time (operate_type=8)":
        "ac 27 08 82 97 ec 6a 20 00 00 00 00 00 00 00 00 00 00 df 76",
    "write: history ack (operate_type=4, 216)":
        "ac 27 04 d8 00 00 00 00 00 00 00 00 00 00 00 00 00 00 df bb",
}


def parse_hex(line: str) -> list[int]:
    s = line.replace(",", " ").replace("0x", " ").replace(":", " ")
    return [int(tok, 16) for tok in s.split()]


def u16be(b: list[int], o: int) -> int:
    return (b[o] << 8) | b[o + 1]


def u16le(b: list[int], o: int) -> int:
    return b[o] | (b[o + 1] << 8)


def u32be(b: list[int], o: int) -> int:
    return int.from_bytes(bytes(b[o:o + 4]), "big")


def u32le(b: list[int], o: int) -> int:
    return int.from_bytes(bytes(b[o:o + 4]), "little")


def checksum_ok(b: list[int]) -> bool:
    if len(b) != 20 or b[0] != 0xAC:
        return False
    return (sum(b[2:19]) & 0x1F) == (b[19] & 0x1F)


def core_fields(core: int) -> dict[str, object]:
    return {
        "weight_g": core & 0x3FFFF,
        "kg_division": (core & 0x1C0000) >> 18,
        "lb_division": (core & 0xE00000) >> 21,
        "dianji": (core >> 24) & 1,
        "supportHr": (core >> 25) & 1,
        "supportPh": (core >> 26) & 1,
        "supportZx": (core >> 27) & 1,
        "has_temperature": (core >> 28) & 1,
        "state": (core >> 31) & 1,
    }


def grams_to_kg(g: int, division: int) -> float:
    """ICCommon.gunit_general(g, division, precision) 的克→千克分支。

    division 0/1/2 → precision 2，否则 precision 1。这里只做演示级近似，
    产品实现见 scalebar 仓库的 Sources/ScaleBarCore/Units.swift。
    """
    if division not in (0, 1, 2):
        return round(g / 1000.0, 1)
    return round(g / 1000.0, 2)


def impedance(adc: int, weight_kg: float) -> float:
    """ICWeightScale27Worker.java:487-500 的换算。"""
    if adc >= 1500:
        return ((adc - 1000.0) + (weight_kg * 10.0 * -0.4)) / 0.6 / 10.0
    return float(adc)


def body(weight_kg: float, z: list[float], h_cm: float = DEMO_H_CM,
         k: float = DEMO_K) -> dict[str, float]:
    """docs/04-body-model.md 的模型。"""
    z_avg = sum(z) / len(z)
    ffm = k * h_cm * h_cm / z_avg
    fat = weight_kg - ffm
    return {
        "Zavg": z_avg,
        "FFM": ffm,
        "fatKg": fat,
        "fatPct": 100 * fat / weight_kg,
        "waterKg": 0.6318 * ffm,
        "proteinKg": 0.3107 * ffm,
        "muscleKg": 0.9509 * ffm,
        "skelMuscleKg": 0.4387 * ffm,
        "BMR": 370 + 21.6 * ffm,
        "BMI": weight_kg / (h_cm / 100) ** 2,
        "TDEE_sedentary": (370 + 21.6 * ffm) * 1.2,
    }


def decode(b: list[int]) -> str:
    head = f"len={len(b)} head=0x{b[0]:02x} cmd=0x{b[18]:02x} chk=0x{b[19]:02x}"
    if not checksum_ok(b):
        return f"{head}  ✗ checksum (sum&0x1F=0x{sum(b[2:19]) & 0x1F:02x})"

    cmd = b[18]
    out = [head + "  ✓ checksum"]

    # 主机写出去的帧：b[1] == 0x27，末尾是 0xDF / 0xD0
    if b[1] == 0x27 and b[18] == 0xDF:
        op = b[2]
        if op == 8:
            out.append(f"  WRITE setTime  time={u32le(b, 3)} utc/900={b[7]}")
        elif op == 4:
            out.append(f"  WRITE reply    reply_cmd={b[3]} (0x{b[3]:02x})")
        else:
            out.append(f"  WRITE setting  operate_type={op}")
        return "\n".join(out)

    if b[1] == 0x27 and b[18] == 0xD0:
        out.append(
            f"  WRITE userInfo time={u32le(b, 2)} utc/900={b[6]} unit={b[7]} "
            f"user={b[8]} height={b[9]}cm weight={u16le(b, 10) / 100:.2f}kg "
            f"age={b[12]} sex={b[13]} target={u16le(b, 14) / 100:.2f}kg "
            f"flags=0x{b[16]:02x} (imp={b[16] & 1})"
        )
        return "\n".join(out)

    if cmd == 0xD5:
        f = core_fields(u32be(b, 2))
        out.append(
            f"  WEIGHT {grams_to_kg(int(f['weight_g']), int(f['kg_division'])):.2f} kg "
            f"(g={f['weight_g']}, kgDiv={f['kg_division']}, lbDiv={f['lb_division']}, "
            f"state={f['state']}, dianji={f['dianji']}) mode={b[6]}"
        )
        return "\n".join(out)

    if cmd == 0xD6:
        p = b[2:18]
        n = p[0]
        adcs = [u16be(p, 2 + 2 * j) for j in range(n)]
        mode = p[2 + 2 * n]
        core = u32be(p, 3 + 2 * n)
        f = core_fields(core)
        w = grams_to_kg(int(f["weight_g"]), int(f["kg_division"]))
        z = [impedance(a, w) for a in adcs]
        out.append(f"  ADC n={n} adcs={adcs} mode={mode} alg={b[17]} weight={w:.2f} kg")
        out.append(f"      impedance={[round(v, 1) for v in z]} Ω  state={f['state']}")
        if all(v > 0 for v in z):
            m = body(w, z)
            out.append(
                f"      BODY fat={m['fatPct']:.1f}% fatKg={m['fatKg']:.1f} "
                f"FFM={m['FFM']:.1f} water={m['waterKg']:.1f}kg "
                f"protein={m['proteinKg']:.1f}kg muscle={m['muscleKg']:.1f}kg "
                f"skel={m['skelMuscleKg']:.1f}kg BMR={m['BMR']:.0f}kcal "
                f"BMI={m['BMI']:.1f} Zavg={m['Zavg']:.1f}"
            )
        else:
            out.append("      ! zero impedance — 拒绝算体脂（脚未贴电极 / fun_open_imp=0）")
        return "\n".join(out)

    if cmd == 0xD8:
        f = core_fields(u32be(b, 7))
        out.append(
            f"  HISTORY kind={b[2]} time={u32be(b, 3)} weight="
            f"{grams_to_kg(int(f['weight_g']), int(f['kg_division'])):.2f} kg "
            f"state={f['state']}  → 必须回 history-ack(216)"
        )
        return "\n".join(out)

    out.append(f"  (未处理的命令字 0x{cmd:02x})")
    return "\n".join(out)


def self_test() -> None:
    w = parse_hex(FRAMES["weight  (0xD5 78.40 kg, state=1)"])
    a = parse_hex(FRAMES["adc     (0xD6 Z=500/514 Ω)"])
    h = parse_hex(FRAMES["history (0xD8 offline record)"])
    u = parse_hex(FRAMES["write: user info (imp=1, 175cm/42y/male/78.40kg)"])
    assert all(checksum_ok(parse_hex(v)) for v in FRAMES.values())
    assert core_fields(u32be(w, 2))["weight_g"] == 78400
    assert core_fields(u32be(w, 2))["state"] == 1
    p = a[2:18]
    assert [u16be(p, 2), u16be(p, 4)] == [500, 514]
    assert core_fields(u32be(p, 7))["weight_g"] == 78400
    assert u32be(h, 7) & 0x3FFFF == 78400
    assert u[9] == 175 and u[12] == 42 and u[13] == 1 and u[16] & 1 == 1
    m = body(DEMO_W, list(DEMO_Z))
    assert 24 < m["fatPct"] < 25, m
    print("自检通过：6 帧校验和、体重位域、两路阻抗、用户信息、体成分模型均一致。\n")


def main() -> None:
    self_test()
    if len(sys.argv) > 1:
        for line in Path(sys.argv[1]).read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                b = parse_hex(line)
            except ValueError:
                continue
            if len(b) == 20:
                print(decode(b))
        return
    for label, hexline in FRAMES.items():
        print(f"--- {label}")
        print(decode(parse_hex(hexline)))
    print("\n（全部为合成演示值，见 docs/07-privacy.md）")


if __name__ == "__main__":
    main()
