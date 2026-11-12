import math, sys
C=128
def svg(body, title, defs=""):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256" role="img"><title>{title}</title>{("<defs>"+defs+"</defs>") if defs else ""}{body}</svg>\n'

# A — Shutter Bloom: 6 aperture blades as curved petals, round opening
def concept_a(colors=None, R=108, r=22, rho=58, g=9):
    defs=""; body=""
    cols = colors or ["#111"]*6
    for k in range(6):
        a1=math.radians(k*60-90+75); a2=math.radians((k+1)*60-90+75)
        c1=(C+rho*math.cos(a1), C+rho*math.sin(a1)); c2=(C+rho*math.cos(a2), C+rho*math.sin(a2))
        defs+=f'<mask id="m{k}" maskUnits="userSpaceOnUse" x="0" y="0" width="256" height="256"><rect width="256" height="256" fill="#000"/><circle cx="{c2[0]:.2f}" cy="{c2[1]:.2f}" r="{rho-g/2}" fill="#fff"/><circle cx="{c1[0]:.2f}" cy="{c1[1]:.2f}" r="{rho+g/2}" fill="#000"/><circle cx="{C}" cy="{C}" r="{r+g/2}" fill="#000"/></mask>'
        body+=f'<circle cx="{C}" cy="{C}" r="{R}" fill="{cols[k]}" mask="url(#m{k})"/>'
    return defs, body

# B — Photo Bud: three photo cards fanned from one pivot into a tulip
def concept_b(colors=None, bg="#fff", w=80, h=124, rx=26, ang=30, pivot=(128,212)):
    cols = colors or ["#111"]*3
    px,py=pivot; body=""
    for i,a in [(0,-ang),(2,ang),(1,0)]:
        x=px-w/2; y=py-h-18
        body+=f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{cols[i]}" stroke="{bg}" stroke-width="{8 if i==1 else 0}" transform="rotate({a} {px} {py})"/>'
    return "", body

# C — b-bloom: lowercase b, counter is a four-petal flower
def quatrefoil(cx,cy,d,rr):
    # four circles radius rr at distance d; outer boundary
    s=d*math.sqrt(2)/2  # half distance between adjacent centres
    h=math.sqrt(rr*rr - s*s)
    pts=[]
    for k in range(4):
        m=math.radians(45+90*k)  # direction of intersection between petal k and k+1
        dist=d*math.cos(math.radians(45)) - h  # inner intersection? use outer
        dist=d*math.cos(math.radians(45)) + h
        pts.append((cx+dist*math.cos(m), cy+dist*math.sin(m)))
    # inner intersections are the ones close to center; we need the outer contour => use points between petals near centre
    inner=[]
    for k in range(4):
        m=math.radians(45+90*k)
        dist=d*math.cos(math.radians(45)) - h
        inner.append((cx+dist*math.cos(m), cy+dist*math.sin(m)))
    p=f"M{inner[3][0]:.2f} {inner[3][1]:.2f} "
    for k in range(4):
        p+=f"A{rr} {rr} 0 1 1 {inner[k][0]:.2f} {inner[k][1]:.2f} "
    return p+"Z"

def concept_c(color="#111"):
    stem=f"M52 52 A22 22 0 0 1 96 52 V214 H52 Z"
    bx,by,BR=146,150,70
    bowl=f"M{bx} {by-BR} A{BR} {BR} 0 1 1 {bx} {by+BR} A{BR} {BR} 0 1 1 {bx} {by-BR} Z"
    counter=quatrefoil(bx,by,20,22)
    # stem + bowl drawn as one nonzero path; counter cut with reversed winding via evenodd on separate compound
    body=f'<path fill="{color}" d="{stem}"/><path fill="{color}" fill-rule="evenodd" d="{bowl} {counter}"/>'
    return "", body

if __name__=="__main__":
    out=sys.argv[1]
    for name,fn in [("a",concept_a),("b",concept_b),("c",concept_c)]:
        d,b=fn()
        open(f"{out}/concept-{name}-v1.svg","w").write(svg(b,f"Bloom concept {name.upper()}",d))
