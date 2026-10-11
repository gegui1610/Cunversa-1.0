// Copia o site (index.html + logo.png) da pasta de cima para app/ (cópia reserva usada se o site estiver fora do ar).
const fs = require("fs"), path = require("path");
const root = path.join(__dirname, "..", ".."), dest = path.join(__dirname, "..", "app");
fs.mkdirSync(dest, { recursive: true });
for (const f of ["index.html", "logo.png"]) {
  const src = path.join(root, f);
  if (fs.existsSync(src)) { fs.copyFileSync(src, path.join(dest, f)); console.log("copiado:", f); }
}
