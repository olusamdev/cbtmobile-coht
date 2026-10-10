import * as XLSX from "npm:xlsx@0.18.5/xlsx.mjs";
import {
  AlignmentType,
  Document,
  HeadingLevel,
  Packer,
  Paragraph,
  ShadingType,
  Table,
  TableCell,
  TableRow,
  TextRun,
  WidthType,
} from "npm:docx@8.5.0";

export type SheetMeta = {
  examTitle: string;
  courseCode: string;
  courseTitle: string;
  sessionName: string;
  generatedAt: string;
};

export type SheetRow = {
  reg_no: string;
  full_name: string;
  programme_name: string | null;
  level: number | null;
  result_status: string;
  answered: number | null;
  correct: number | null;
  wrong: number | null;
  unanswered: number | null;
  total: number | null;
  percentage: number | string | null;
  submitted_at: string | null;
};

export type SheetSummary = {
  registered: number;
  sat: number;
  absent: number;
  average: number | null;
  highest: number | null;
  lowest: number | null;
};

const pct = (row: SheetRow) => (row.percentage == null ? null : Number(row.percentage));

export function summarize(rows: SheetRow[]): SheetSummary {
  const scores = rows.filter((r) => r.result_status === "Submitted").map(pct).filter((v): v is number => v != null);
  return {
    registered: rows.length,
    sat: scores.length,
    absent: rows.length - scores.length,
    average: scores.length ? Math.round((scores.reduce((a, b) => a + b, 0) / scores.length) * 10) / 10 : null,
    highest: scores.length ? Math.max(...scores) : null,
    lowest: scores.length ? Math.min(...scores) : null,
  };
}

const fmtDate = (value: string | null) =>
  value ? new Date(value).toLocaleString("en-GB", { timeZone: "Africa/Lagos", hour12: false }) : "";

const fmtScore = (row: SheetRow) => {
  const v = pct(row);
  return v == null ? "" : Number.isInteger(v) ? String(v) : v.toFixed(1);
};

export function sheetFileBase(meta: SheetMeta) {
  return `${meta.courseCode}-results`.replace(/[^A-Za-z0-9_-]+/g, "_");
}

/** Excel result sheet: a summary block followed by one row per registered student. */
export function buildXlsx(meta: SheetMeta, rows: SheetRow[]): Uint8Array {
  const s = summarize(rows);
  const head = [
    "S/N", "Matric number", "Full name", "Programme", "Level", "Status",
    "Answered", "Correct", "Wrong", "Unanswered", "Total questions", "Score (%)", "Submitted at",
  ];
  const aoa: (string | number | null)[][] = [
    [`${meta.courseCode} · ${meta.courseTitle}`],
    [`Examination: ${meta.examTitle}`],
    [`Session: ${meta.sessionName}`],
    [`Generated: ${fmtDate(meta.generatedAt)}`],
    [
      `Registered: ${s.registered}`, `Sat: ${s.sat}`, `Absent: ${s.absent}`,
      `Average: ${s.average ?? "-"}%`, `Highest: ${s.highest ?? "-"}%`, `Lowest: ${s.lowest ?? "-"}%`,
    ],
    [],
    head,
    ...rows.map((r, i) => [
      i + 1, r.reg_no, r.full_name, r.programme_name ?? "", r.level ?? "", r.result_status,
      r.answered ?? "", r.correct ?? "", r.wrong ?? "", r.unanswered ?? "", r.total ?? "",
      pct(r) ?? "", fmtDate(r.submitted_at),
    ]),
  ];

  const ws = XLSX.utils.aoa_to_sheet(aoa);
  ws["!cols"] = [6, 18, 30, 26, 8, 12, 10, 9, 8, 12, 15, 10, 20].map((wch) => ({ wch }));
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, "Results");
  return new Uint8Array(XLSX.write(wb, { type: "array", bookType: "xlsx" }));
}

/** Word result sheet: a heading, a summary line and a compact result table. */
export async function buildDocx(meta: SheetMeta, rows: SheetRow[]): Promise<Uint8Array> {
  const s = summarize(rows);
  const cell = (text: string, opts: { bold?: boolean; fill?: string; width?: number; align?: (typeof AlignmentType)[keyof typeof AlignmentType] } = {}) =>
    new TableCell({
      width: opts.width ? { size: opts.width, type: WidthType.PERCENTAGE } : undefined,
      shading: opts.fill ? { type: ShadingType.CLEAR, fill: opts.fill, color: "auto" } : undefined,
      children: [
        new Paragraph({
          alignment: opts.align,
          children: [new TextRun({ text, bold: opts.bold, size: 18 })],
        }),
      ],
    });

  const header = new TableRow({
    tableHeader: true,
    children: [
      cell("S/N", { bold: true, fill: "E5E7EB", width: 6 }),
      cell("Matric number", { bold: true, fill: "E5E7EB", width: 20 }),
      cell("Full name", { bold: true, fill: "E5E7EB", width: 34 }),
      cell("Status", { bold: true, fill: "E5E7EB", width: 12 }),
      cell("Correct / Total", { bold: true, fill: "E5E7EB", width: 16 }),
      cell("Score (%)", { bold: true, fill: "E5E7EB", width: 12 }),
    ],
  });

  const body = rows.map(
    (r, i) =>
      new TableRow({
        children: [
          cell(String(i + 1), { width: 6 }),
          cell(r.reg_no, { width: 20 }),
          cell(r.full_name, { width: 34 }),
          cell(r.result_status, { width: 12 }),
          cell(r.total == null ? "" : `${r.correct ?? 0} / ${r.total}`, { width: 16 }),
          cell(fmtScore(r), { width: 12, align: AlignmentType.RIGHT }),
        ],
      }),
  );

  const doc = new Document({
    sections: [
      {
        children: [
          new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun({ text: `${meta.courseCode} · ${meta.courseTitle}` })] }),
          new Paragraph({ children: [new TextRun({ text: `Examination: ${meta.examTitle}` })] }),
          new Paragraph({ children: [new TextRun({ text: `Session: ${meta.sessionName}` })] }),
          new Paragraph({ children: [new TextRun({ text: `Generated: ${fmtDate(meta.generatedAt)}`, color: "666666" })] }),
          new Paragraph({
            spacing: { before: 160, after: 160 },
            children: [
              new TextRun({
                text: `Registered ${s.registered} · Sat ${s.sat} · Absent ${s.absent} · Average ${s.average ?? "-"}% · Highest ${s.highest ?? "-"}% · Lowest ${s.lowest ?? "-"}%`,
                bold: true,
              }),
            ],
          }),
          new Table({ width: { size: 100, type: WidthType.PERCENTAGE }, rows: [header, ...body] }),
        ],
      },
    ],
  });

  return new Uint8Array(await Packer.toBuffer(doc));
}

const esc = (t: string) => t.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c] ?? c);

export function emailBody(meta: SheetMeta, rows: SheetRow[]): string {
  const s = summarize(rows);
  return `<div style="font-family:Arial,sans-serif;font-size:14px;color:#111">
<p>Results for <b>${esc(meta.courseCode)} · ${esc(meta.courseTitle)}</b> (${esc(meta.examTitle)}, ${esc(meta.sessionName)}) are attached as Excel and Word sheets.</p>
<table cellpadding="6" style="border-collapse:collapse;border:1px solid #ccc">
<tr><td>Registered</td><td><b>${s.registered}</b></td></tr>
<tr><td>Sat</td><td><b>${s.sat}</b></td></tr>
<tr><td>Absent</td><td><b>${s.absent}</b></td></tr>
<tr><td>Average score</td><td><b>${s.average ?? "-"}%</b></td></tr>
<tr><td>Highest / lowest</td><td><b>${s.highest ?? "-"}% / ${s.lowest ?? "-"}%</b></td></tr>
</table>
<p style="color:#666">Sent automatically by the College CBT portal when the examination was closed.</p></div>`;
}
