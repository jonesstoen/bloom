import math, itertools
C=128.0
PALETTE=["#FF8A00","#FFC400","#2FC96B","#1EB3F0","#5A5CF2","#FF3D7F"]  # orange→pink, clockwise from top
INK="#1C1C1E"

def circ_inter(c1,r1,c2,r2):
    dx,dy=c2[0]-c1[0],c2[1]-c1[1]; d=math.hypot(dx,dy)
    if d>r1+r2 or d<abs(r1-r2) or d==0: return []
    a=(r1*r1-r2*r2+d*d)/(2*d); h=math.sqrt(max(r1*r1-a*a,0))
    mx,my=c1[0]+a*dx/d, c1[1]+a*dy/d
    return [(mx+h*dy/d,my-h*dx/d),(mx-h*dy/d,my+h*dx/d)]

def blade_path(k, R=108, r=22, rho=58, g=9, phase=-15):
    a1=math.radians(k*60+phase); a2=math.radians((k+1)*60+phase)
    c1=(C+rho*math.cos(a1), C+rho*math.sin(a1)); c2=(C+rho*math.cos(a2), C+rho*math.sin(a2))
    # constraints: (centre, radius, inside?)
    cons=[((C,C),R,True),(c2,rho-g/2,True),(c1,rho+g/2,False),((C,C),r+g/2,False)]
    def ok(p,skip=None,eps=1e-6):
        for i,(cc,rr,ins) in enumerate(cons):
            if i==skip: continue
            dd=math.hypot(p[0]-cc[0],p[1]-cc[1])
            if ins and dd>rr+eps: return False
            if not ins and dd<rr-eps: return False
        return True
    verts=[]
    for i,j in itertools.combinations(range(4),2):
        for p in circ_inter(cons[i][0],cons[i][1],cons[j][0],cons[j][1]):
            if ok(p,eps=1e-4): verts.append((p,{i,j}))
    # walk boundary: start at a vertex, follow circle arcs
    def arc_mid(cc,rr,p,q,ccw):
        a=math.atan2(p[1]-cc[1],p[0]-cc[0]); b=math.atan2(q[1]-cc[1],q[0]-cc[0])
        da=(b-a)%(2*math.pi) if ccw else -((a-b)%(2*math.pi))
        m=a+da/2; return (cc[0]+rr*math.cos(m),cc[1]+rr*math.sin(m)), abs(da)
    path=[]; cur=verts[0]; start=cur; used_circle=None
    for _ in range(len(verts)):
        p,cs=cur
        found=None
        for ci in cs:
            if ci==used_circle: continue
            cc,rr,_=cons[ci]
            for q,qs in verts:
                if q==p or ci not in qs: continue
                for ccw in (True,False):
                    m,span=arc_mid(cc,rr,p,q,ccw)
                    if ok(m,eps=1e-3):
                        if found is None or span<found[3]: found=(q,qs,ci,span,ccw,rr)
        q,qs,ci,span,ccw,rr=found
        large=1 if span>math.pi else 0; sweep=1 if ccw else 0  # SVG y-down: increasing angle = clockwise visually = sweep 1
        path.append(f"A{rr:g} {rr:g} 0 {large} {sweep} {q[0]:.2f} {q[1]:.2f}")
        used_circle=ci; cur=(q,qs)
        if q==start[0]: break
    return f"M{start[0][0]:.2f} {start[0][1]:.2f} "+" ".join(path)+" Z"

def symbol(colors=None, soft=4, R=108, r=22, rho=58, g=9):
    # morphological opening: erode by `soft`, then dilate with a round-join stroke of 2*soft -> rounded convex corners
    cols=colors or [INK]*6
    return "".join(f'<path id="blade-{k+1}" fill="{cols[k]}" stroke="{cols[k]}" stroke-width="{2*soft}" stroke-linejoin="round" d="{blade_path(k,R=R-soft,r=r,rho=rho,g=g+2*soft)}"/>' for k in range(6))

def doc(body, title, vb="0 0 256 256", w=256, h=256):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{w}" height="{h}" role="img" aria-labelledby="title"><title id="title">{title}</title>{body}</svg>\n'

# ---- wordmark "bloom": geometric monoline, outlined as filled paths (rings via evenodd, stems as rounded rects)
def ring(cx,cy,ro,ri):
    return f"M{cx-ro} {cy} A{ro} {ro} 0 1 0 {cx+ro} {cy} A{ro} {ro} 0 1 0 {cx-ro} {cy} Z M{cx-ri} {cy} A{ri} {ri} 0 1 1 {cx+ri} {cy} A{ri} {ri} 0 1 1 {cx-ri} {cy} Z"
def stem(x,top,bot,w):  # round top, flat bottom
    r=w/2; return f"M{x} {top+r} A{r} {r} 0 0 1 {x+w} {top+r} V{bot} H{x} Z"
def stem_rb(x,top,bot,w):  # flat top (joins arch), round bottom
    r=w/2; return f"M{x} {top} H{x+w} V{bot-r} A{r} {r} 0 0 1 {x} {bot-r} Z"
def wordmark(color=INK, x0=0, base=200, xh=112, sw=26, asc=186):
    # x-height circle diameter = xh ; stem width sw
    ro=xh/2; ri=ro-sw; cy=base-ro; top=base-asc; gap=18; parts=[]; x=x0
    # b
    parts.append(stem(x,top,base,sw)); parts.append(ring(x+ro- 0 + 0, cy, ro, ri).replace(f"M{x-ro+ro}",f"M{x}") if False else ring(x+ro,cy,ro,ri)); x+=xh+gap
    # l
    parts.append(stem(x,top,base,sw)); x+=sw+gap
    # o o
    parts.append(ring(x+ro,cy,ro,ri)); x+=xh+gap
    parts.append(ring(x+ro,cy,ro,ri)); x+=xh+gap
    # m: two arches of outer width (xh*0.8) sharing middle stem
    aw=xh*0.86; ar=aw/2; ir=ar-sw; at=base-xh
    def arch(xl):
        return f"M{xl} {base} V{at+ar} A{ar} {ar} 0 0 1 {xl+aw} {at+ar} V{base} H{xl+aw-sw} V{at+ar} A{ir} {ir} 0 0 0 {xl+sw} {at+ar} V{base} Z"
    parts.append(arch(x)); parts.append(arch(x+aw-sw))
    x+=2*aw-sw
    return "".join(f'<path fill="{color}" fill-rule="evenodd" d="{p}"/>' for p in parts), x-x0

if __name__=="__main__":
    import os; o="kit"
    open(f"{o}/bloom-symbol-color.svg","w").write(doc(symbol(PALETTE),"Bloom logo"))
    open(f"{o}/bloom-symbol.svg","w").write(doc(symbol(),"Bloom logo"))
    open(f"{o}/bloom-symbol-small.svg","w").write(doc(symbol(PALETTE,R=112,r=26,g=18,soft=5),"Bloom logo (small sizes)"))
    wm,wmw=wordmark()
    open(f"{o}/bloom-wordmark.svg","w").write(doc(wm,"Bloom wordmark",f"-8 0 {wmw+16:.0f} 256",round(wmw+16),256))
    # horizontal lockup: symbol 256, gap 40, wordmark (baseline aligned optically with symbol centre)
    def horiz(colors, inkc):
        wm,wmw=wordmark(inkc, x0=0)
        sc=0.6; W=256+36+wmw*sc+8
        ty=128-(200-56)*sc - 4   # x-height band centred a hair above symbol centre
        return doc(f'<g id="symbol">{symbol(colors)}</g><g id="wordmark" transform="translate(292 {ty:.1f}) scale({sc})">{wm}</g>',"Bloom logo",f"0 0 {W:.0f} 256",round(W),256)
    open(f"{o}/bloom-horizontal-color.svg","w").write(horiz(PALETTE,INK))
    open(f"{o}/bloom-horizontal-on-dark.svg","w").write(horiz(PALETTE,"#FFFFFF"))
    open(f"{o}/bloom-horizontal.svg","w").write(horiz(None,INK))
    def stacked(colors,inkc):
        wm,wmw=wordmark(inkc); s=0.42; W=max(256,wmw*s)+24
        return doc(f'<g transform="translate({(W-256)/2:.1f} 0)">{symbol(colors)}</g><g transform="translate({(W-wmw*s)/2:.1f} 262) scale({s})">{wm}</g>',"Bloom logo",f"0 0 {W:.0f} 360",round(W),360)
    open(f"{o}/bloom-stacked-color.svg","w").write(stacked(PALETTE,INK))
    open(f"{o}/bloom-stacked-on-dark.svg","w").write(stacked(PALETTE,"#FFFFFF"))
    # iOS app icons 1024 (light / dark / tinted) + Icon Composer foreground layer
    def icon(bg, cols, scale=0.74, sym_kw={}):
        t=f"translate(128 128) scale({scale}) translate(-128 -128)"
        return doc(f'<rect width="256" height="256" fill="{bg}"/><g transform="{t}">{symbol(cols,**sym_kw)}</g>',"Bloom app icon","0 0 256 256",1024,1024)
    open(f"{o}/bloom-appicon-light.svg","w").write(icon("#FFFFFF",PALETTE))
    open(f"{o}/bloom-appicon-dark.svg","w").write(icon("#000000",PALETTE))
    grey=["#FFFFFF","#E6E6E6","#CCCCCC","#B3B3B3","#999999","#E0E0E0"]
    open(f"{o}/bloom-appicon-tinted.svg","w").write(icon("#000000",["#D9D9D9"]*6))
    open(f"{o}/bloom-appicon-foreground.svg","w").write(doc(f'<g transform="translate(512 512) scale(2.96) translate(-128 -128)">{symbol(PALETTE)}</g>',"Bloom icon foreground","0 0 1024 1024",1024,1024))
    print("ok", wmw)
