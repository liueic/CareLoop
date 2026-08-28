#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pyreadstat",
#   "pandas",
#   "numpy",
# ]
# ///
"""Convert VentureD NHANES XPT + GBD zip into a read-only SQLite warehouse.

Usage:
  uv run scripts/nhanes_to_sqlite.py \\
    --zip "/Users/liueic/Downloads/VentureD data.zip" \\
    --out-dir data
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import sqlite3
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
import pyreadstat

def food_code_str(value) -> str:
    if value is None or (isinstance(value, float) and np.isnan(value)):
        return ""
    if isinstance(value, (int, np.integer)):
        return str(int(value))
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    text = str(value).strip()
    if text.endswith(".0"):
        try:
            return str(int(float(text)))
        except ValueError:
            return text[:-2]
    return text

EMBED_DIM = 384
EMBED_MODEL = "hashing-char3gram-384"
SLIM_LIMIT = 3000


def decode_zip_name(info: zipfile.ZipInfo) -> str:
    if info.flag_bits & 0x800:
        return info.filename
    try:
        return info.filename.encode("cp437").decode("utf-8")
    except UnicodeError:
        return info.filename


def extract_zip(zip_path: Path, dest: Path) -> Path:
    dest.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            name = decode_zip_name(info)
            target = dest / name
            if info.is_dir() or name.endswith("/"):
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(zf.read(info))
    return dest


def find_dir(root: Path, needle: str) -> Path | None:
    for path in root.rglob("*"):
        if path.is_dir() and needle in path.name:
            return path
    return None


def find_file(root: Path, suffix: str) -> Path | None:
    matches = [p for p in root.rglob("*") if p.name.endswith(suffix) and "__MACOSX" not in str(p)]
    return matches[0] if matches else None


def col(df: pd.DataFrame, *candidates: str) -> str | None:
    upper = {c.upper(): c for c in df.columns}
    for cand in candidates:
        if cand.upper() in upper:
            return upper[cand.upper()]
    for cand in candidates:
        key = cand.upper()
        for name, original in upper.items():
            if name.endswith(key) or key in name:
                return original
    return None


def read_xpt(path: Path, columns: list[str] | None = None) -> pd.DataFrame:
    try:
        df, _meta = pyreadstat.read_xport(str(path), encoding="latin1")
    except (UnicodeDecodeError, Exception):
        df = pd.read_sas(path, format="xport", encoding="latin-1")
    if columns:
        present = [c for c in columns if c in df.columns]
        if present:
            df = df[present]
    return df


def hash_embed(text: str, dim: int = EMBED_DIM) -> bytes:
    vec = np.zeros(dim, dtype=np.float32)
    value = (text or "").lower()
    if len(value) < 3:
        value = f"_{value}_"
    for i in range(max(len(value) - 2, 1)):
        gram = value[i : i + 3].encode("utf-8", errors="ignore")
        digest = hashlib.blake2b(gram, digest_size=8).digest()
        idx = int.from_bytes(digest[:4], "little") % dim
        sign = 1.0 if digest[4] % 2 == 0 else -1.0
        vec[idx] += sign
    norm = np.linalg.norm(vec)
    if norm > 0:
        vec /= norm
    return vec.tobytes()


def yes(series: pd.Series | None) -> pd.Series:
    if series is None:
        return pd.Series(dtype="float64")
    return series.map(lambda v: 1 if v == 1 else (0 if v in (2, 0) else None))


def write_meta(conn: sqlite3.Connection, source_zip: Path) -> None:
    conn.execute(
        """
        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """
    )
    rows = {
        "source_zip": str(source_zip),
        "cycle": "NHANES August 2021–August 2023",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "weight_note": "NHANES 是复杂抽样。人群估计必须使用对应模块权重与 SDMVSTRA/SDMVPSU，不能把未加权比例当成全国患病率。美国结果不能直接宣称适用于中国人群。",
        "embedding_model": EMBED_MODEL,
        "embedding_dim": str(EMBED_DIM),
    }
    conn.executemany("INSERT INTO meta(key, value) VALUES (?, ?)", list(rows.items()))


def load_demo(xpt_dir: Path, conn: sqlite3.Connection) -> None:
    path = xpt_dir / "DEMO_L.xpt"
    df = read_xpt(path)
    seqn = col(df, "SEQN")
    age = col(df, "RIDAGEYR")
    sex = col(df, "RIAGENDR")
    wt_int = col(df, "WTINTPRP", "WTINT2YR", "WTINT2YR")
    wt_mec = col(df, "WTMECPRP", "WTMEC2YR")
    strata = col(df, "SDMVSTRA")
    psu = col(df, "SDMVPSU")
    out = pd.DataFrame(
        {
            "seqn": df[seqn],
            "age_years": df[age] if age else None,
            "sex_code": df[sex] if sex else None,
            "interview_weight": df[wt_int] if wt_int else None,
            "mec_weight": df[wt_mec] if wt_mec else None,
            "strata": df[strata] if strata else None,
            "psu": df[psu] if psu else None,
        }
    )
    out.to_sql("participants", conn, if_exists="replace", index=False)


def load_exam(xpt_dir: Path, conn: sqlite3.Connection) -> None:
    bmx_path = xpt_dir / "BMX_L.xpt"
    bpx_path = xpt_dir / "BPXO_L.xpt"
    if bmx_path.exists():
        df = read_xpt(bmx_path)
        out = pd.DataFrame(
            {
                "seqn": df[col(df, "SEQN")],
                "bmi": df[col(df, "BMXBMI")] if col(df, "BMXBMI") else None,
                "weight_kg": df[col(df, "BMXWT")] if col(df, "BMXWT") else None,
                "height_cm": df[col(df, "BMXHT")] if col(df, "BMXHT") else None,
                "waist_cm": df[col(df, "BMXWAIST")] if col(df, "BMXWAIST") else None,
            }
        )
        out.to_sql("exam_bmx", conn, if_exists="replace", index=False)
    if bpx_path.exists():
        df = read_xpt(bpx_path)
        out = pd.DataFrame(
            {
                "seqn": df[col(df, "SEQN")],
                "sbp": df[col(df, "BPXOSY1", "BPXOSY", "BPXSY1")] if col(df, "BPXOSY1", "BPXOSY", "BPXSY1") else None,
                "dbp": df[col(df, "BPXODI1", "BPXODI", "BPXDI1")] if col(df, "BPXODI1", "BPXODI", "BPXDI1") else None,
            }
        )
        out.to_sql("exam_bpx", conn, if_exists="replace", index=False)


def load_labs(xpt_dir: Path, conn: sqlite3.Connection) -> None:
    frames: list[pd.DataFrame] = []
    mapping = {
        "GHB_L.xpt": [("GHB", "hba1c", "LBXGH")],
        "GLU_L.xpt": [("GLU", "fasting_glucose", "LBXGLU")],
        "HDL_L.xpt": [("HDL", "hdl", "LBDHDD")],
        "TCHOL_L.xpt": [("TCHOL", "total_chol", "LBXTC")],
        "TRIGLY_L.xpt": [("TRIG", "triglycerides", "LBXTR"), ("LDL", "ldl", "LBDLDL")],
        "INS_L.xpt": [("INS", "insulin", "LBXIN")],
    }
    for filename, fields in mapping.items():
        path = xpt_dir / filename
        if not path.exists():
            continue
        df = read_xpt(path)
        seqn = col(df, "SEQN")
        piece = pd.DataFrame({"seqn": df[seqn]})
        for _label, dest, candidate in fields:
            found = col(df, candidate)
            piece[dest] = df[found] if found else None
        frames.append(piece)
    if not frames:
        return
    merged = frames[0]
    for frame in frames[1:]:
        merged = merged.merge(frame, on="seqn", how="outer")
    merged.to_sql("labs", conn, if_exists="replace", index=False)


def load_conditions(xpt_dir: Path, conn: sqlite3.Connection) -> None:
    rows = None
    diq = xpt_dir / "DIQ_L.xpt"
    bpq = xpt_dir / "BPQ_L.xpt"
    mcq = xpt_dir / "MCQ_L.xpt"
    if diq.exists():
        df = read_xpt(diq)
        rows = pd.DataFrame({"seqn": df[col(df, "SEQN")], "diabetes": yes(df[col(df, "DIQ010")]) if col(df, "DIQ010") else None})
    if bpq.exists():
        df = read_xpt(bpq)
        piece = pd.DataFrame(
            {
                "seqn": df[col(df, "SEQN")],
                "hypertension": yes(df[col(df, "BPQ020")]) if col(df, "BPQ020") else None,
            }
        )
        rows = piece if rows is None else rows.merge(piece, on="seqn", how="outer")
    if mcq.exists():
        df = read_xpt(mcq)
        piece = pd.DataFrame(
            {
                "seqn": df[col(df, "SEQN")],
                "chd": yes(df[col(df, "MCQ160C")]) if col(df, "MCQ160C") else None,
                "heart_attack": yes(df[col(df, "MCQ160E")]) if col(df, "MCQ160E") else None,
                "stroke": yes(df[col(df, "MCQ160F")]) if col(df, "MCQ160F") else None,
            }
        )
        rows = piece if rows is None else rows.merge(piece, on="seqn", how="outer")
    if rows is not None:
        rows.to_sql("conditions", conn, if_exists="replace", index=False)


def load_food_codes(xpt_dir: Path, conn: sqlite3.Connection) -> pd.DataFrame:
    path = xpt_dir / "DRXFCD_L.xpt"
    df = read_xpt(path)
    code = col(df, "DRXFDCD")
    short = col(df, "DRXFCSD")
    long = col(df, "DRXFCLD")
    out = pd.DataFrame(
        {
            "food_code": df[code].map(food_code_str),
            "short_desc": df[short].astype(str) if short else "",
            "long_desc": df[long].astype(str) if long else "",
        }
    )
    out.to_sql("food_codes", conn, if_exists="replace", index=False)
    return out


def aggregate_iff(path: Path) -> pd.DataFrame:
    df = read_xpt(path)
    food = col(df, "DR1IFDCD", "DR2IFDCD", "DRDIFDCD")
    if not food:
        raise SystemExit(f"no food code column in {path}: {list(df.columns)[:20]}")
    work = pd.DataFrame({"food_code": df[food].map(food_code_str)})
    mapping = {
        "grams": ("DR1IGRMS", "DR2IGRMS"),
        "kcal": ("DR1IKCAL", "DR2IKCAL"),
        "sodium_mg": ("DR1ISODI", "DR2ISODI"),
        "sugar_g": ("DR1ISUGR", "DR2ISUGR"),
        "satfat_g": ("DR1ISFAT", "DR2ISFAT"),
        "fiber_g": ("DR1IFIBE", "DR2IFIBE"),
    }
    for dest, candidates in mapping.items():
        found = col(df, *candidates)
        if found:
            work[dest] = pd.to_numeric(df[found], errors="coerce")
    named = {"n_obs": ("food_code", "size")}
    for name in ("grams", "kcal", "sodium_mg", "sugar_g", "satfat_g", "fiber_g"):
        if name in work.columns:
            named[f"mean_{name}"] = (name, "mean")
            named[f"sum_{name}"] = (name, "sum")
    out = work.groupby("food_code", dropna=True).agg(**named).reset_index()
    grams_sum = out["sum_grams"].replace(0, np.nan) if "sum_grams" in out.columns else None
    if grams_sum is not None:
        for src, dest in (
            ("sum_kcal", "kcal_per_100g"),
            ("sum_sodium_mg", "sodium_mg_per_100g"),
            ("sum_sugar_g", "sugar_g_per_100g"),
            ("sum_satfat_g", "satfat_g_per_100g"),
            ("sum_fiber_g", "fiber_g_per_100g"),
        ):
            if src in out.columns:
                out[dest] = out[src] / grams_sum * 100
    drop_cols = [c for c in out.columns if c.startswith("sum_")]
    return out.drop(columns=drop_cols)


def load_food_agg(xpt_dir: Path, conn: sqlite3.Connection) -> pd.DataFrame:
    frames = []
    for name in ("DR1IFF_L.xpt", "DR2IFF_L.xpt"):
        path = xpt_dir / name
        if path.exists():
            print(f"aggregating {name} ...")
            frames.append(aggregate_iff(path))
    if not frames:
        return pd.DataFrame()
    all_rows = pd.concat(frames, ignore_index=True)
    numeric = [c for c in all_rows.columns if c != "food_code"]
    grouped = all_rows.groupby("food_code", as_index=False).agg(
        {**{c: "sum" if c == "n_obs" else "mean" for c in numeric}}
    )
    grouped.to_sql("food_nutrient_agg", conn, if_exists="replace", index=False)
    return grouped


def load_day_totals(xpt_dir: Path, conn: sqlite3.Connection) -> None:
    frames = []
    for day, name in ((1, "DR1TOT_L.xpt"), (2, "DR2TOT_L.xpt")):
        path = xpt_dir / name
        if not path.exists():
            continue
        df = read_xpt(path)
        seqn = col(df, "SEQN")
        piece = pd.DataFrame({"seqn": df[seqn], "day": day})
        for dest, candidates in {
            "energy_kcal": ("DR1TKCAL", "DR2TKCAL"),
            "sodium_mg": ("DR1TSODI", "DR2TSODI"),
            "sugar_g": ("DR1TSUGR", "DR2TSUGR"),
            "satfat_g": ("DR1TSFAT", "DR2TSFAT"),
            "fiber_g": ("DR1TFIBE", "DR2TFIBE"),
        }.items():
            found = col(df, *candidates)
            piece[dest] = pd.to_numeric(df[found], errors="coerce") if found else None
        frames.append(piece)
    if frames:
        pd.concat(frames, ignore_index=True).to_sql("day_totals", conn, if_exists="replace", index=False)


def load_gbd(root: Path, conn: sqlite3.Connection) -> None:
    csv_path = None
    for path in root.rglob("*.zip"):
        if path.name.startswith(".") or "__MACOSX" in str(path):
            continue
        try:
            with zipfile.ZipFile(path) as zf:
                for name in zf.namelist():
                    if name.endswith(".csv"):
                        data = zf.read(name)
                        csv_path = name
                        df = pd.read_csv(io.BytesIO(data))
                        df.to_sql("gbd_mortality", conn, if_exists="replace", index=False)
                        print(f"loaded GBD csv {csv_path} ({len(df)} rows)")
                        return
        except zipfile.BadZipFile:
            continue
    conn.execute("CREATE TABLE IF NOT EXISTS gbd_mortality (note TEXT)")


def load_embeddings(food_codes: pd.DataFrame, conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE embeddings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            target_table TEXT NOT NULL,
            target_id TEXT NOT NULL,
            model TEXT NOT NULL,
            dim INTEGER NOT NULL,
            vector BLOB NOT NULL
        )
        """
    )
    rows = []
    for rec in food_codes.itertuples(index=False):
        text = f"{rec.short_desc} {rec.long_desc}".strip()
        rows.append(("food_codes", rec.food_code, EMBED_MODEL, EMBED_DIM, hash_embed(text)))
    conn.executemany(
        "INSERT INTO embeddings(target_table, target_id, model, dim, vector) VALUES (?, ?, ?, ?, ?)",
        rows,
    )


def export_slim(food_codes: pd.DataFrame, agg: pd.DataFrame, dest: Path) -> None:
    merged = food_codes.merge(agg, on="food_code", how="left") if not agg.empty else food_codes.copy()
    if "n_obs" in merged.columns:
        merged = merged.sort_values("n_obs", ascending=False)
    slim = merged.head(SLIM_LIMIT)
    records = []
    for rec in slim.itertuples(index=False):
        item = {
            "food_code": str(rec.food_code),
            "short_desc": getattr(rec, "short_desc", "") or "",
            "long_desc": getattr(rec, "long_desc", "") or "",
        }
        for key in (
            "n_obs",
            "kcal_per_100g",
            "sodium_mg_per_100g",
            "sugar_g_per_100g",
            "satfat_g_per_100g",
            "fiber_g_per_100g",
        ):
            if hasattr(rec, key):
                value = getattr(rec, key)
                if pd.notna(value):
                    item[key] = int(value) if key == "n_obs" else round(float(value), 3)
        records.append(item)
    dest.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote slim catalog {dest} ({len(records)} foods)")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip", dest="zip_path", required=True, type=Path)
    parser.add_argument("--out-dir", dest="out_dir", default=Path("data"), type=Path)
    parser.add_argument("--app-catalog", dest="app_catalog", default=Path("CareLoop/Resources/Content/food_catalog_slim.json"), type=Path)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    sqlite_path = args.out_dir / "nhanes_careloop.sqlite"
    if sqlite_path.exists():
        sqlite_path.unlink()

    with tempfile.TemporaryDirectory() as tmp:
        root = extract_zip(args.zip_path, Path(tmp) / "extracted")
        nhanes = find_dir(root, "健康与营养学基准数据") or find_dir(root, "NHANES")
        if nhanes is None:
            xpt_dir = next(root.rglob("xpt"), None)
        else:
            xpt_dir = nhanes / "xpt"
        if xpt_dir is None or not xpt_dir.exists():
            raise SystemExit(f"Could not find xpt/ under {root}")
        print(f"using xpt dir {xpt_dir}")

        conn = sqlite3.connect(sqlite_path)
        try:
            write_meta(conn, args.zip_path)
            print("loading DEMO")
            load_demo(xpt_dir, conn)
            print("loading exam")
            load_exam(xpt_dir, conn)
            print("loading labs")
            load_labs(xpt_dir, conn)
            print("loading conditions")
            load_conditions(xpt_dir, conn)
            print("loading food codes")
            food_codes = load_food_codes(xpt_dir, conn)
            print("loading day totals")
            load_day_totals(xpt_dir, conn)
            agg = load_food_agg(xpt_dir, conn)
            print("loading GBD")
            load_gbd(root, conn)
            print(f"embedding {len(food_codes)} food codes")
            load_embeddings(food_codes, conn)
            conn.execute("CREATE INDEX IF NOT EXISTS idx_embeddings_target ON embeddings(target_table, target_id)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_food_codes ON food_codes(food_code)")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_food_agg ON food_nutrient_agg(food_code)")
            conn.commit()
        finally:
            conn.close()

        export_slim(food_codes, agg, args.out_dir / "food_catalog_slim.json")
        args.app_catalog.parent.mkdir(parents=True, exist_ok=True)
        export_slim(food_codes, agg, args.app_catalog)
        print(f"sqlite {sqlite_path} ({sqlite_path.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
