# Generates the topology diagrams in this directory.
#   python3 docs/diagrams/make.py docs/diagrams
# Edit a diagram here, not in the .svg it writes.
import sys, html
OUT = sys.argv[1]
INK="#1f2933"; MUTED="#52606d"; LINE="#7b8794"
BLUE=("#e6f0ff","#2b6cb0"); GREEN=("#e3f6ea","#2f855a"); AMBER=("#fff4d6","#b7791f"); GREY=("#f1f3f5","#7b8794"); ROSE=("#fde8e8","#c53030")
def box(x,y,w,h,title,lines=(),col=BLUE,bold=True):
    s=f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{col[0]}" stroke="{col[1]}" stroke-width="1.5"/>'
    n=len(lines); ty=y+h/2-(n*17)/2+ (5 if n==0 else -2)
    s+=f'<text x="{x+w/2}" y="{ty}" text-anchor="middle" font-size="14" font-weight="{600 if bold else 400}" fill="{INK}">{html.escape(title)}</text>'
    for i,l in enumerate(lines):
        s+=f'<text x="{x+w/2}" y="{ty+18+i*17}" text-anchor="middle" font-size="12.5" fill="{MUTED}">{html.escape(l)}</text>'
    return s
def zone(x,y,w,h,label,col="#2f855a"):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="none" stroke="{col}" stroke-width="1.5" stroke-dasharray="7 5"/>'
            f'<text x="{x+14}" y="{y+22}" font-size="13" font-weight="600" fill="{col}">{html.escape(label)}</text>')
def arrow(x1,y1,x2,y2,label=None,lx=None,ly=None,col=LINE,anchor="middle"):
    s=f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{col}" stroke-width="1.8" marker-end="url(#a)"/>'
    if label:
        lx = (x1+x2)/2 if lx is None else lx; ly=(y1+y2)/2-7 if ly is None else ly
        for i,l in enumerate(label.split("\n")):
            s+=f'<text x="{lx}" y="{ly+i*15}" text-anchor="{anchor}" font-size="12" fill="{MUTED}">{html.escape(l)}</text>'
    return s
def note(x,y,t,size=13,col=MUTED,anchor="middle",weight=400):
    return f'<text x="{x}" y="{y}" text-anchor="{anchor}" font-size="{size}" font-weight="{weight}" fill="{col}">{html.escape(t)}</text>'
def svg(name,w,h,title,desc,body):
    open(f"{OUT}/{name}.svg","w").write(
f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" aria-labelledby="t d" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif">
<title id="t">{html.escape(title)}</title><desc id="d">{html.escape(desc)}</desc>
<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="{LINE}"/></marker></defs>
<rect width="{w}" height="{h}" rx="12" fill="#ffffff" stroke="#d9dee3"/>
{body}
</svg>
''')

# 1. one box
b  = note(400,34,"One box: everything on a single server",16,INK,weight=600)
b += box(30,120,170,80,"Your team",["browsers, scripts,","S3 clients"],GREY)
b += zone(260,70,510,200,"One server you own")
b += box(285,110,210,60,"TMach server",["console, API, job queue"])
b += box(285,190,210,60,"Database and documents",["SQLite or PostgreSQL"],GREY)
b += box(545,140,200,80,"Model server",["Ollama or llama-server","on the same machine"],GREEN)
b += arrow(200,150,283,142)
b += arrow(495,145,543,165)
b += note(400,300,"Nothing leaves this machine. Works with no internet connection.")
svg("topology-one-box",800,325,"One-box deployment","A team connects to one server that runs TMach, its database, and a local model server. Nothing leaves the machine.",b)

# 2. tailnet with workers
b  = note(450,34,"Workers: add GPU machines to share the load",16,INK,weight=600)
b += zone(215,60,665,345,"Your private network (LAN or tailnet)")
b += box(20,180,160,80,"Your team",["anywhere on the","private network"],GREY)
b += box(245,150,230,70,"TMach server",["console, API, permissions"])
b += box(245,230,230,60,"Job queue",["budgets and limits per team"],AMBER)
b += box(245,300,230,60,"Database and documents",[],GREY)
ys=[95,205,315]
names=["GPU machine, office","GPU machine, rack","Workstation, after hours"]
for y,n in zip(ys,names):
    b += box(630,y,225,75,n,["worker + model server"],GREEN)
    b += arrow(628,y+38,477,260)
b += arrow(180,205,243,190)
b += note(540,98,"workers connect out",12)
b += note(540,113,"and pull jobs from the queue",12)
b += note(450,432,"Each worker runs one job at a time. GPU machines need no open ports. Add a machine and the team gets more capacity.")
svg("topology-workers",900,455,"Deployment with GPU workers","GPU machines run a worker and a model server. Workers connect to the TMach server over a private network and pull jobs from its queue.",b)

# 3. hybrid
b  = note(450,34,"Hybrid: local models for sensitive work, a cloud model for the rest",16,INK,weight=600)
b += zone(20,60,590,330,"Your private network")
b += box(40,105,235,65,"TMach server",["documents stay here"])
b += box(40,190,235,150,"Your rules, per document label",["confidential: local only","internal: cloud if names","and IDs are removed","public: either"],AMBER)
b += box(385,105,205,75,"Local model or workers",["on your own hardware"],GREEN)
b += box(385,265,205,75,"Request log",["every model call, the host","it went to, no prompt text"],GREY)
b += box(670,150,205,90,"Cloud model",["any OpenAI-compatible","endpoint"],ROSE)
b += arrow(275,138,383,140,"sensitive work",330,128)
b += arrow(275,235,668,200,"only what the rules allow",470,238)
b += arrow(275,300,383,302)
b += note(450,418,"A request that breaks a rule is refused before anything is sent, and the refusal is recorded.")
svg("topology-hybrid",900,440,"Hybrid deployment","The TMach server sends sensitive work to local models and sends other work to a cloud model only when the per-label rules allow it. Every model call is logged.",b)
