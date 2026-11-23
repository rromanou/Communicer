// Syntaxe CSS via postcss (échec seulement sur erreur de syntaxe)
const postcss=require('postcss'),fs=require('fs');let bad=0;
for(const f of fs.readdirSync('style').filter(x=>x.endsWith('.css'))){
  try{postcss.parse(fs.readFileSync('style/'+f,'utf8'),{from:'style/'+f});console.log(f,'OK')}catch(e){console.log(`::error file=style/${f},line=${e.line}::${e.reason}`);bad++}}
process.exit(bad?1:0);
