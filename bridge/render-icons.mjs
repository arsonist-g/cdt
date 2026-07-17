// render-icons.mjs — 用 @resvg/resvg-js 把 cdt-master.svg 栅格化为 128/48/16 PNG(透明背景, 高质量抗锯齿)
// 比 puppeteer 截图可靠: 直接栅格化 SVG, 无浏览器加载/缩放问题(之前 img+setContent 导致 16px 空白)。
import { Resvg } from "@resvg/resvg-js";
import fs from "node:fs";
import path from "node:path";

const ICONS = String.raw`d:\Dev\Repos\arsonist-g\cdt\extension\icons`;
const svg = fs.readFileSync(path.join(ICONS, "cdt-master.svg"), "utf-8");

for (const sz of [128, 48, 16]) {
  const resvg = new Resvg(svg, {
    fitTo: { mode: "width", value: sz },
    background: "rgba(0,0,0,0)",
  });
  const png = resvg.render().asPng();
  fs.writeFileSync(path.join(ICONS, `cdt-${sz}.png`), png);
  console.log(`rendered cdt-${sz}.png (${sz}x${sz}, ${png.length} bytes)`);
}
console.log("done");
