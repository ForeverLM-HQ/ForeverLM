"use strict";var ForeverLMPublishedPage=(()=>{var Qu=Object.create;var Qe=Object.defineProperty;var ec=Object.getOwnPropertyDescriptor;var rc=Object.getOwnPropertyNames;var tc=Object.getPrototypeOf,nc=Object.prototype.hasOwnProperty;var ic=(e,r,t)=>()=>{if(t)throw t[0];try{return e&&(r=e(e=0)),r}catch(n){throw t=[n],n}};var f=(e,r)=>()=>{try{return r||e((r={exports:{}}).exports,r),r.exports}catch(t){throw r=0,t}},ac=(e,r)=>{for(var t in r)Qe(e,t,{get:r[t],enumerable:!0})},ei=(e,r,t,n)=>{if(r&&typeof r=="object"||typeof r=="function")for(let i of rc(r))!nc.call(e,i)&&i!==t&&Qe(e,i,{get:()=>r[i],enumerable:!(n=ec(r,i))||n.enumerable});return e};var ri=(e,r,t)=>(t=e!=null?Qu(tc(e)):{},ei(r||!e||!e.__esModule?Qe(t,"default",{value:e,enumerable:!0}):t,e)),sc=e=>ei(Qe({},"__esModule",{value:!0}),e);var O=f((c0,ti)=>{"use strict";o();ti.exports=function(e){try{return!!e()}catch{return!0}}});var er=f((f0,ni)=>{"use strict";o();var oc=O();ni.exports=!oc(function(){var e=function(){}.bind();return typeof e!="function"||e.hasOwnProperty("prototype")})});var k=f((h0,si)=>{"use strict";o();var ii=er(),ai=Function.prototype,Xr=ai.call,lc=ii&&ai.bind.bind(Xr,Xr);si.exports=ii?lc:function(e){return function(){return Xr.apply(e,arguments)}}});var ge=f((g0,li)=>{"use strict";o();var oi=k(),uc=oi({}.toString),cc=oi("".slice);li.exports=function(e){return cc(uc(e),8,-1)}});var Qr=f((b0,ui)=>{"use strict";o();var dc=k(),fc=O(),pc=ge(),Jr=Object,hc=dc("".split);ui.exports=fc(function(){return!Jr("z").propertyIsEnumerable(0)})?function(e){return pc(e)==="String"?hc(e,""):Jr(e)}:Jr});var rr=f((y0,ci)=>{"use strict";o();ci.exports=function(e){return e==null}});var Oe=f((S0,di)=>{"use strict";o();var vc=rr(),gc=TypeError;di.exports=function(e){if(vc(e))throw new gc("Can't call method on "+e);return e}});var me=f((E0,fi)=>{"use strict";o();var mc=Qr(),bc=Oe();fi.exports=function(e){return mc(bc(e))}});var R=f((et,pi)=>{"use strict";o();var Ae=function(e){return e&&e.Math===Math&&e};pi.exports=Ae(typeof globalThis=="object"&&globalThis)||Ae(typeof window=="object"&&window)||Ae(typeof self=="object"&&self)||Ae(typeof global=="object"&&global)||Ae(typeof et=="object"&&et)||(function(){return this})()||Function("return this")()});var be=f((P0,hi)=>{"use strict";o();hi.exports=!1});var tr=f((R0,gi)=>{"use strict";o();var vi=R(),xc=Object.defineProperty;gi.exports=function(e,r){try{xc(vi,e,{value:r,configurable:!0,writable:!0})}catch{vi[e]=r}return r}});var nr=f((O0,xi)=>{"use strict";o();var yc=be(),wc=R(),Sc=tr(),mi="__core-js_shared__",bi=xi.exports=wc[mi]||Sc(mi,{});(bi.versions||(bi.versions=[])).push({version:"3.50.0",mode:yc?"pure":"global",copyright:"\xA9 2013\u20132025 Denis Pushkarev (zloirock.ru), 2025\u20132026 CoreJS Company (core-js.io). All rights reserved.",license:"https://github.com/zloirock/core-js/blob/v3.50.0/LICENSE",source:"https://github.com/zloirock/core-js"})});var rt=f((C0,wi)=>{"use strict";o();var yi=nr(),qc=Object.create||Object;wi.exports=function(e,r){return yi[e]||(yi[e]=r||qc(null))}});var Ce=f((F0,Si)=>{"use strict";o();var Ec=Oe(),kc=Object;Si.exports=function(e){return kc(Ec(e))}});var _=f((N0,qi)=>{"use strict";o();var Ic=k(),Pc=Ce(),Tc=Ic({}.hasOwnProperty);qi.exports=Object.hasOwn||function(r,t){return Tc(Pc(r),t)}});var tt=f((M0,Ei)=>{"use strict";o();var Rc=k(),$c=0,Oc=Math.random(),Ac=Rc(1.1.toString);Ei.exports=function(e){return"Symbol("+(e===void 0?"":e)+")_"+Ac(++$c+Oc,36)}});var Ti=f((j0,Pi)=>{"use strict";o();var Cc=R(),ki=Cc.navigator,Ii=ki&&ki.userAgent;Pi.exports=Ii?String(Ii):""});var Fi=f((H0,Li)=>{"use strict";o();var Ci=R(),nt=Ti(),Ri=Ci.process,$i=Ci.Deno,Oi=Ri&&Ri.versions||$i&&$i.version,Ai=Oi&&Oi.v8,U,ir;Ai&&(U=Ai.split("."),ir=U[0]>0&&U[0]<4?1:+(U[0]+U[1]));!ir&&nt&&(U=nt.match(/Edge\/(\d+)/),(!U||U[1]>=74)&&(U=nt.match(/Chrome\/(\d+)/),U&&(ir=+U[1])));Li.exports=ir});var it=f((G0,Ni)=>{"use strict";o();var _i=Fi(),Lc=O(),Fc=R(),_c=Fc.String;Ni.exports=!!Object.getOwnPropertySymbols&&!Lc(function(){var e=Symbol("symbol detection");return!_c(e)||!(Object(e)instanceof Symbol)||!Symbol.sham&&_i&&_i<41})});var at=f((W0,Di)=>{"use strict";o();var Nc=it();Di.exports=Nc&&!Symbol.sham&&typeof Symbol.iterator=="symbol"});var N=f((Y0,Bi)=>{"use strict";o();var Dc=R(),Mc=rt(),Mi=_(),Bc=tt(),jc=it(),Uc=at(),xe=Dc.Symbol,st=Mc("wks"),Hc=Uc?xe.for||xe:xe&&xe.withoutSetter||Bc;Bi.exports=function(e){return Mi(st,e)||(st[e]=jc&&Mi(xe,e)?xe[e]:Hc("Symbol."+e)),st[e]}});var I=f((X0,ji)=>{"use strict";o();var ot=typeof document=="object"&&document.all;ji.exports=typeof ot>"u"&&ot!==void 0?function(e){return typeof e=="function"||e===ot}:function(e){return typeof e=="function"}});var V=f((Q0,Ui)=>{"use strict";o();var zc=I();Ui.exports=function(e){return typeof e=="object"?e!==null:zc(e)}});var J=f((rx,Hi)=>{"use strict";o();var Gc=V(),Kc=String,Wc=TypeError;Hi.exports=function(e){if(Gc(e))return e;throw new Wc(Kc(e)+" is not an object")}});var P=f((nx,zi)=>{"use strict";o();var Vc=O();zi.exports=!Vc(function(){return Object.defineProperty({},1,{get:function(){return 7}})[1]!==7})});var lt=f((ax,Gi)=>{"use strict";o();var Yc=P(),Zc=O();Gi.exports=Yc&&Zc(function(){return Object.defineProperty(function(){},"prototype",{value:42,writable:!1}).prototype!==42})});var ct=f((ox,Wi)=>{"use strict";o();var Xc=R(),Ki=V(),ut=Xc.document,Jc=Ki(ut)&&Ki(ut.createElement);Wi.exports=function(e){return Jc?ut.createElement(e):{}}});var dt=f((ux,Vi)=>{"use strict";o();var Qc=P(),ed=O(),rd=ct();Vi.exports=!Qc&&!ed(function(){return Object.defineProperty(rd("div"),"a",{get:function(){return 7}}).a!==7})});var H=f((dx,Yi)=>{"use strict";o();var td=er(),ar=Function.prototype.call;Yi.exports=td?ar.bind(ar):function(){return ar.apply(ar,arguments)}});var ie=f((px,Zi)=>{"use strict";o();var ft=R(),nd=I(),id=function(e){return nd(e)?e:void 0};Zi.exports=function(e,r){return arguments.length<2?id(ft[e]):ft[e]&&ft[e][r]}});var pt=f((vx,Xi)=>{"use strict";o();var ad=k();Xi.exports=ad({}.isPrototypeOf)});var ht=f((mx,Ji)=>{"use strict";o();var sd=ie(),od=I(),ld=pt(),ud=at(),cd=Object;Ji.exports=ud?function(e){return typeof e=="symbol"}:function(e){var r=sd("Symbol");return od(r)&&ld(r.prototype,cd(e))}});var vt=f((xx,Qi)=>{"use strict";o();var dd=String;Qi.exports=function(e){try{return dd(e)}catch{return"Object"}}});var sr=f((wx,ea)=>{"use strict";o();var fd=I(),pd=vt(),hd=TypeError;ea.exports=function(e){if(fd(e))return e;throw new hd(pd(e)+" is not a function")}});var or=f((qx,ra)=>{"use strict";o();var vd=sr(),gd=rr();ra.exports=function(e,r){var t=e[r];return gd(t)?void 0:vd(t)}});var na=f((kx,ta)=>{"use strict";o();var gt=H(),mt=I(),bt=V(),md=TypeError;ta.exports=function(e,r){var t,n;if(r==="string"&&mt(t=e.toString)&&!bt(n=gt(t,e))||mt(t=e.valueOf)&&!bt(n=gt(t,e))||r!=="string"&&mt(t=e.toString)&&!bt(n=gt(t,e)))return n;throw new md("Can't convert object to primitive value")}});var oa=f((Px,sa)=>{"use strict";o();var bd=H(),ia=V(),aa=ht(),xd=or(),yd=na(),wd=N(),Sd=TypeError,qd=wd("toPrimitive");sa.exports=function(e,r){if(!ia(e)||aa(e))return e;var t=xd(e,qd),n;if(t){if(r===void 0&&(r="default"),n=bd(t,e,r),!ia(n)||aa(n))return n;throw new Sd("Can't convert object to primitive value")}return r===void 0&&(r="number"),yd(e,r)}});var xt=f((Rx,la)=>{"use strict";o();var Ed=oa(),kd=ht();la.exports=function(e){var r=Ed(e,"string");return kd(r)?r:r+""}});var Y=f(ca=>{"use strict";o();var Id=P(),Pd=dt(),Td=lt(),lr=J(),ua=xt(),Rd=TypeError,yt=Object.defineProperty,$d=Object.getOwnPropertyDescriptor,wt="enumerable",St="configurable",qt="writable";ca.f=Id?Td?function(r,t,n){if(lr(r),t=ua(t),lr(n),typeof r=="function"&&t==="prototype"&&"value"in n&&qt in n&&!n[qt]){var i=$d(r,t);i&&i[qt]&&(r[t]=n.value,n={configurable:St in n?n[St]:i[St],enumerable:wt in n?n[wt]:i[wt],writable:!1})}return yt(r,t,n)}:yt:function(r,t,n){if(lr(r),t=ua(t),lr(n),Pd)try{return yt(r,t,n)}catch{}if("get"in n||"set"in n)throw new Rd("Accessors not supported");return"value"in n&&(r[t]=n.value),r}});var fa=f((Cx,da)=>{"use strict";o();var Od=Math.ceil,Ad=Math.floor;da.exports=Math.trunc||function(r){var t=+r;return(t>0?Ad:Od)(t)}});var ur=f((Fx,pa)=>{"use strict";o();var Cd=fa();pa.exports=function(e){var r=+e;return r!==r||r===0?0:Cd(r)}});var Et=f((Nx,ha)=>{"use strict";o();var Ld=ur(),Fd=Math.max,_d=Math.min;ha.exports=function(e,r){var t=Ld(e);return t<0?Fd(t+r,0):_d(t,r)}});var ga=f((Mx,va)=>{"use strict";o();var Nd=ur(),Dd=Math.min;va.exports=function(e){var r=Nd(e);return r>0?Dd(r,9007199254740991):0}});var kt=f((jx,ma)=>{"use strict";o();var Md=ga();ma.exports=function(e){return Md(e.length)}});var ya=f((Hx,xa)=>{"use strict";o();var Bd=me(),jd=Et(),Ud=kt(),ba=function(e){return function(r,t,n){var i=Bd(r),a=Ud(i);if(a===0)return!e&&-1;var s=jd(n,a),l;if(e&&t!==t){for(;a>s;)if(l=i[s++],l!==l)return!0}else for(;a>s;s++)if((e||s in i)&&i[s]===t)return e||s||0;return!e&&-1}};xa.exports={includes:ba(!0),indexOf:ba(!1)}});var cr=f((Gx,wa)=>{"use strict";o();wa.exports={}});var Pt=f((Wx,qa)=>{"use strict";o();var Hd=k(),It=_(),zd=me(),Gd=ya().indexOf,Kd=cr(),Sa=Hd([].push);qa.exports=function(e,r){var t=zd(e),n=0,i=[],a;for(a in t)!It(Kd,a)&&It(t,a)&&Sa(i,a);for(;r.length>n;)It(t,a=r[n++])&&(~Gd(i,a)||Sa(i,a));return i}});var dr=f((Yx,Ea)=>{"use strict";o();Ea.exports=["constructor","hasOwnProperty","isPrototypeOf","propertyIsEnumerable","toLocaleString","toString","valueOf"]});var Tt=f((Xx,ka)=>{"use strict";o();var Wd=Pt(),Vd=dr();ka.exports=Object.keys||function(r){return Wd(r,Vd)}});var Pa=f(Ia=>{"use strict";o();var Yd=P(),Zd=lt(),Xd=Y(),Jd=J(),Qd=me(),ef=Tt();Ia.f=Yd&&!Zd?Object.defineProperties:function(r,t){Jd(r);for(var n=Qd(t),i=ef(t),a=i.length,s=0,l;a>s;)Xd.f(r,l=i[s++],n[l]);return r}});var Ra=f((ry,Ta)=>{"use strict";o();var rf=ie();Ta.exports=rf("document","documentElement")});var fr=f((ny,Oa)=>{"use strict";o();var tf=rt(),nf=tt(),$a=tf("keys");Oa.exports=function(e){return $a[e]||($a[e]=nf(e))}});var Le=f((ay,Da)=>{"use strict";o();var af=J(),sf=Pa(),Aa=dr(),of=cr(),lf=Ra(),uf=ct(),cf=fr(),Ca=">",La="<",$t="prototype",Ot="script",_a=cf("IE_PROTO"),Rt=function(){},Na=function(e){return La+Ot+Ca+e+La+"/"+Ot+Ca},Fa=function(e){e.write(Na("")),e.close();var r=e.parentWindow.Object;return e=null,r},df=function(){var e=uf("iframe"),r="java"+Ot+":",t;return e.style.display="none",lf.appendChild(e),e.src=String(r),t=e.contentWindow.document,t.open(),t.write(Na("document.F=Object")),t.close(),t.F},pr,hr=function(){try{pr=new ActiveXObject("htmlfile")}catch{}hr=typeof document<"u"?document.domain&&pr?Fa(pr):df():Fa(pr);for(var e=Aa.length;e--;)delete hr[$t][Aa[e]];return hr()};of[_a]=!0;Da.exports=Object.create||function(r,t){var n;return r!==null?(Rt[$t]=af(r),n=new Rt,Rt[$t]=null,n[_a]=r):n=hr(),t===void 0?n:sf.f(n,t)}});var Ba=f((oy,Ma)=>{"use strict";o();var ff=N(),pf=Le(),hf=Y().f,At=ff("unscopables"),Ct=Array.prototype;Ct[At]===void 0&&hf(Ct,At,{configurable:!0,value:pf(null)});Ma.exports=function(e){Ct[At][e]=!0}});var Fe=f((uy,ja)=>{"use strict";o();ja.exports=Object.create?Object.create(null):{}});var za=f((dy,Ha)=>{"use strict";o();var vf=R(),gf=I(),Ua=vf.WeakMap;Ha.exports=gf(Ua)&&/native code/.test(String(Ua))});var ye=f((py,Ga)=>{"use strict";o();Ga.exports=function(e,r){return{enumerable:!(e&1),configurable:!(e&2),writable:!(e&4),value:r}}});var vr=f((vy,Ka)=>{"use strict";o();var mf=P(),bf=Y(),xf=ye();Ka.exports=mf?function(e,r,t){return bf.f(e,r,xf(1,t))}:function(e,r,t){return e[r]=t,e}});var we=f((my,Ya)=>{"use strict";o();var yf=za(),Va=R(),wf=V(),Sf=vr(),Lt=_(),Ft=nr(),qf=fr(),Ef=cr(),Wa="Object already initialized",_t=Va.TypeError,kf=Va.WeakMap,gr,_e,mr,If=function(e){return mr(e)?_e(e):gr(e,{})},Pf=function(e){return function(r){var t;if(!wf(r)||(t=_e(r)).type!==e)throw new _t("Incompatible receiver, "+e+" required");return t}};yf||Ft.state?(z=Ft.state||(Ft.state=new kf),z.get=z.get,z.has=z.has,z.set=z.set,gr=function(e,r){if(z.has(e))throw new _t(Wa);return r.facade=e,z.set(e,r),r},_e=function(e){return z.get(e)||{}},mr=function(e){return z.has(e)}):(le=qf("state"),Ef[le]=!0,gr=function(e,r){if(Lt(e,le))throw new _t(Wa);return r.facade=e,Sf(e,le,r),r},_e=function(e){return Lt(e,le)?e[le]:{}},mr=function(e){return Lt(e,le)});var z,le;Ya.exports={set:gr,get:_e,has:mr,enforce:If,getterFor:Pf}});var Nt=f(Ja=>{"use strict";o();var Za={}.propertyIsEnumerable,Xa=Object.getOwnPropertyDescriptor,Tf=Xa&&!Za.call({1:2},1);Ja.f=Tf?function(r){var t=Xa(this,r);return!!t&&t.enumerable}:Za});var Dt=f(es=>{"use strict";o();var Rf=P(),$f=H(),Of=Nt(),Af=ye(),Cf=me(),Lf=xt(),Ff=_(),_f=dt(),Qa=Object.getOwnPropertyDescriptor;es.f=Rf?Qa:function(r,t){if(r=Cf(r),t=Lf(t),_f)try{return Qa(r,t)}catch{}if(Ff(r,t))return Af(!$f(Of.f,r,t),r[t])}});var jt=f((qy,ts)=>{"use strict";o();var Mt=P(),Nf=_(),rs=Function.prototype,Df=Mt&&Object.getOwnPropertyDescriptor,Bt=Nf(rs,"name"),Mf=Bt&&function(){}.name==="something",Bf=Bt&&(!Mt||Mt&&Df(rs,"name").configurable);ts.exports={EXISTS:Bt,PROPER:Mf,CONFIGURABLE:Bf}});var Ht=f((ky,ns)=>{"use strict";o();var jf=k(),Uf=I(),Ut=nr(),Hf=jf(Function.toString);Uf(Ut.inspectSource)||(Ut.inspectSource=function(e){return Hf(e)});ns.exports=Ut.inspectSource});var Kt=f((Py,ss)=>{"use strict";o();var Gt=k(),zf=O(),Gf=I(),br=_(),zt=P(),Kf=jt().CONFIGURABLE,Wf=Ht(),as=we(),Vf=as.enforce,Yf=as.get,is=String,xr=Object.defineProperty,Zf=Gt("".slice),Xf=Gt("".replace),Jf=Gt([].join),Qf=zt&&!zf(function(){return xr(function(){},"length",{value:8}).length!==8}),ep=String(String).split("String"),rp=ss.exports=function(e,r,t){Zf(is(r),0,7)==="Symbol("&&(r="["+Xf(is(r),/^Symbol\(([^)]*)\).*$/,"$1")+"]"),t&&t.getter&&(r="get "+r),t&&t.setter&&(r="set "+r),(!br(e,"name")||Kf&&e.name!==r)&&(zt?xr(e,"name",{value:r,configurable:!0}):e.name=r),Qf&&t&&br(t,"arity")&&e.length!==t.arity&&xr(e,"length",{value:t.arity});try{t&&br(t,"constructor")&&t.constructor?zt&&xr(e,"prototype",{writable:!1}):e.prototype&&(e.prototype=void 0)}catch{}var n=Vf(e);return br(n,"source")||(n.source=Jf(ep,typeof r=="string"?r:"")),e};Function.prototype.toString=rp(function(){return Gf(this)&&Yf(this).source||Wf(this)},"toString")});var Q=f((Ry,os)=>{"use strict";o();var tp=I(),np=Y(),ip=Kt(),ap=tr();os.exports=function(e,r,t,n){n||(n={});var i=n.enumerable,a=n.name!==void 0?n.name:r;if(tp(t)&&ip(t,a,n),n.global)i?e[r]=t:ap(r,t);else{try{n.unsafe?e[r]&&(i=!0):delete e[r]}catch{}i?e[r]=t:np.f(e,r,{value:t,enumerable:!1,configurable:!n.nonConfigurable,writable:!n.nonWritable})}return e}});var us=f(ls=>{"use strict";o();var sp=Pt(),op=dr(),lp=op.concat("length","prototype");ls.f=Object.getOwnPropertyNames||function(r){return sp(r,lp)}});var Wt=f(cs=>{"use strict";o();cs.f=Object.getOwnPropertySymbols});var fs=f((Fy,ds)=>{"use strict";o();var up=ie(),cp=k(),dp=us(),fp=Wt(),pp=J(),hp=cp([].concat);ds.exports=up("Reflect","ownKeys")||function(r){var t=dp.f(pp(r)),n=fp.f;return n?hp(t,n(r)):t}});var vs=f((Ny,hs)=>{"use strict";o();var ps=_(),vp=fs(),gp=Dt(),mp=Y();hs.exports=function(e,r,t){for(var n=vp(r),i=mp.f,a=gp.f,s=0;s<n.length;s++){var l=n[s];!ps(e,l)&&!(t&&ps(t,l))&&i(e,l,a(r,l))}}});var ms=f((My,gs)=>{"use strict";o();var bp=O(),xp=I(),yp=/#|\.prototype\./,Ne=function(e,r){var t=Sp[wp(e)];return t===Ep?!0:t===qp?!1:xp(r)?bp(r):!!r},wp=Ne.normalize=function(e){return String(e).replace(yp,".").toLowerCase()},Sp=Ne.data={},qp=Ne.NATIVE="N",Ep=Ne.POLYFILL="P";gs.exports=Ne});var ae=f((jy,bs)=>{"use strict";o();var yr=R(),kp=Dt().f,Ip=vr(),Pp=Q(),Tp=tr(),Rp=vs(),$p=ms();bs.exports=function(e,r){var t=e.target,n=e.global,i=e.stat,a,s,l,u,d,p;if(n?s=yr:i?s=yr[t]||Tp(t,{}):s=yr[t]&&yr[t].prototype,s)for(l in r){if(d=r[l],e.dontCallGetSet?(p=kp(s,l),u=p&&p.value):u=s[l],a=$p(n?l:t+(i?".":"#")+l,e.forced),!a&&u!==void 0){if(typeof d==typeof u)continue;Rp(d,u)}(e.sham||u&&u.sham)&&Ip(d,"sham",!0),Pp(s,l,d,e)}}});var ys=f((Hy,xs)=>{"use strict";o();var Op=O();xs.exports=!Op(function(){function e(){}return e.prototype.constructor=null,Object.getPrototypeOf(new e)!==e.prototype})});var Yt=f((Gy,Ss)=>{"use strict";o();var Ap=_(),Cp=I(),Lp=Ce(),Fp=fr(),_p=ys(),ws=Fp("IE_PROTO"),Vt=Object,Np=Vt.prototype;Ss.exports=_p?Vt.getPrototypeOf:function(e){var r=Lp(e);if(Ap(r,ws))return r[ws];var t=r.constructor;return Cp(t)&&r instanceof t?t.prototype:r instanceof Vt?Np:null}});var Qt=f((Wy,ks)=>{"use strict";o();var Dp=O(),Mp=I(),Bp=V(),jp=Le(),qs=Yt(),Up=Q(),Hp=N(),zp=be(),Jt=Hp("iterator"),Es=!1,ee,Zt,Xt;[].keys&&(Xt=[].keys(),"next"in Xt?(Zt=qs(qs(Xt)),Zt!==Object.prototype&&(ee=Zt)):Es=!0);var Gp=!Bp(ee)||Dp(function(){var e={};return ee[Jt].call(e)!==e});Gp?ee={}:zp&&(ee=jp(ee));Mp(ee[Jt])||Up(ee,Jt,function(){return this});ks.exports={IteratorPrototype:ee,BUGGY_SAFARI_ITERATORS:Es}});var De=f((Yy,Ps)=>{"use strict";o();var Kp=Y().f,Wp=_(),Vp=N(),Is=Vp("toStringTag");Ps.exports=function(e,r,t){e&&!t&&(e=e.prototype),e&&!Wp(e,Is)&&Kp(e,Is,{configurable:!0,value:r})}});var en=f((Xy,Ts)=>{"use strict";o();var Yp=Qt().IteratorPrototype,Zp=Le(),Xp=ye(),Jp=De(),Qp=Fe(),eh=function(){return this};Ts.exports=function(e,r,t,n){var i=r+" Iterator";return e.prototype=Zp(Yp,{next:Xp(+!n,t)}),Jp(e,i,!1,!0),Qp[i]=eh,e}});var $s=f((Qy,Rs)=>{"use strict";o();var rh=k(),th=sr();Rs.exports=function(e,r,t){try{return rh(th(Object.getOwnPropertyDescriptor(e,r)[t]))}catch{}}});var As=f((r1,Os)=>{"use strict";o();var nh=V();Os.exports=function(e){return nh(e)||e===null}});var Ls=f((n1,Cs)=>{"use strict";o();var ih=As(),ah=String,sh=TypeError;Cs.exports=function(e){if(ih(e))return e;throw new sh("Can't set "+ah(e)+" as a prototype")}});var _s=f((a1,Fs)=>{"use strict";o();var oh=$s(),lh=V(),uh=Oe(),ch=Ls();Fs.exports=Object.setPrototypeOf||("__proto__"in{}?(function(){var e=!1,r={},t;try{t=oh(Object.prototype,"__proto__","set"),t(r,[]),e=r instanceof Array}catch{}return function(i,a){return uh(i),ch(a),lh(i)&&(e?t(i,a):i.__proto__=a),i}})():void 0)});var tn=f((o1,Ks)=>{"use strict";o();var dh=ae(),fh=H(),wr=be(),zs=jt(),ph=I(),hh=en(),Ns=Yt(),Ds=_s(),vh=De(),gh=vr(),rn=Q(),mh=N(),Ms=Fe(),Gs=Qt(),bh=zs.PROPER,xh=zs.CONFIGURABLE,Bs=Gs.IteratorPrototype,Sr=Gs.BUGGY_SAFARI_ITERATORS,Me=mh("iterator"),js="keys",Be="values",Us="entries",Hs=function(){return this};Ks.exports=function(e,r,t,n,i,a,s){hh(t,r,n);var l=function(g){if(g===i&&h)return h;if(!Sr&&g&&g in p)return p[g];switch(g){case js:return function(){return new t(this,g)};case Be:return function(){return new t(this,g)};case Us:return function(){return new t(this,g)}}return function(){return new t(this)}},u=r+" Iterator",d=!1,p=e.prototype,c=p[Me]||p["@@iterator"]||i&&p[i],h=!Sr&&c||l(i),x=r==="Array"&&p.entries||c,w,v,m;if(x&&(w=Ns(x.call(new e)),w!==Object.prototype&&w.next&&(!wr&&Ns(w)!==Bs&&(Ds?Ds(w,Bs):ph(w[Me])||rn(w,Me,Hs)),vh(w,u,!0,!0),wr&&(Ms[u]=Hs))),bh&&i===Be&&c&&c.name!==Be&&(!wr&&xh?gh(p,"name",Be):(d=!0,h=function(){return fh(c,this)})),i)if(v={values:l(Be),keys:a?h:l(js),entries:l(Us)},s)for(m in v)(Sr||d||!(m in p))&&rn(p,m,v[m]);else dh({target:r,proto:!0,forced:Sr||d},v);return(!wr||s)&&p[Me]!==h&&rn(p,Me,h,{name:i}),Ms[r]=h,v}});var qr=f((u1,Ws)=>{"use strict";o();Ws.exports=function(e,r){return{value:e,done:r}}});var Qs=f((d1,Js)=>{"use strict";o();var yh=me(),nn=Ba(),Vs=Fe(),Zs=we(),wh=Y().f,Sh=tn(),Er=qr(),qh=be(),Eh=P(),Xs="Array Iterator",kh=Zs.set,Ih=Zs.getterFor(Xs);Js.exports=Sh(Array,"Array",function(e,r){kh(this,{type:Xs,target:yh(e),index:0,kind:r})},function(){var e=Ih(this),r=e.target,t=e.index++;if(!r||t>=r.length)return e.target=null,Er(void 0,!0);switch(e.kind){case"keys":return Er(t,!1);case"values":return Er(r[t],!1)}return Er([t,r[t]],!1)},"values");var Ys=Vs.Arguments=Vs.Array;nn("keys");nn("values");nn("entries");if(!qh&&Eh&&Ys.name!=="values")try{wh(Ys,"name",{value:"values"})}catch{}});var to=f((p1,ro)=>{"use strict";o();var eo=R(),Ph=P(),Th=Object.getOwnPropertyDescriptor;ro.exports=function(e){if(!Ph)return eo[e];var r=Th(eo,e);return r&&r.value}});var je=f((v1,io)=>{"use strict";o();var Rh=O(),$h=N(),Oh=P(),no=be(),Ah=$h("iterator");io.exports=!Rh(function(){var e=new URL("b?a=1&b=2&c=3","https://a"),r=e.searchParams,t=new URLSearchParams("a=1&a=2&b=3"),n="";return e.pathname="c%20d",r.forEach(function(i,a){r.delete("b"),n+=a+i}),t.delete("a",2),t.delete("b",void 0),no&&(!e.toJSON||!t.has("a",1)||t.has("a",2)||!t.has("a",void 0)||t.has("b"))||!r.size&&(no||!Oh)||!r.sort||e.href!=="https://a/c%20d?a=1&c=3"||r.get("c")!=="3"||String(new URLSearchParams("?a=1"))!=="a=1"||!r[Ah]||new URL("https://a@b").username!=="a"||new URLSearchParams(new URLSearchParams("a=b")).get("a")!=="b"||new URL("https://\u0442\u0435\u0441\u0442").host!=="xn--e1aybc"||new URL("https://a#\u0431").hash!=="#%D0%B1"||n!=="a1c3"||new URL("https://x",void 0).host!=="x"})});var oo=f(()=>{"use strict";o();var Ch=ae(),Lh=k(),Fh=Et(),_h=RangeError,ao=String.fromCharCode,so=String.fromCodePoint,Nh=Lh([].join),Dh=!!so&&so.length!==1;Ch({target:"String",stat:!0,arity:1,forced:Dh},{fromCodePoint:function(r){for(var t=[],n=arguments.length,i=0,a;n>i;){if(a=+arguments[i],Fh(a,1114111)!==a)throw new _h(a+" is not a valid code point");t[i++]=a<65536?ao(a):ao(((a-=65536)>>10)+55296,a%1024+56320)}return Nh(t,"")}})});var sn=f((y1,co)=>{"use strict";o();oo();var Mh=ie(),Ue=k(),Bh=String.fromCharCode,jh=Mh("String","fromCodePoint"),lo=encodeURIComponent,Uh=parseInt,an=Ue("".charAt),Hh=Ue([].push),zh=Ue("".replace),Gh=Ue("".slice),Kh=Ue(/./.exec),kr="\uFFFD",Wh=/^[0-9a-f]+$/i,Vh=/[\uD800-\uDBFF][\uDC00-\uDFFF]|[\uD800-\uDFFF]/g,uo=function(e,r){var t=Gh(e,r,r+2);return Kh(Wh,t)?Uh(t,16):NaN},Yh=function(e){for(var r=0,t=128;t>0&&(e&t)!==0;t>>=1)r++;return r},Zh=function(e){var r=null,t=e.length;switch(t){case 1:r=e[0];break;case 2:r=(e[0]&31)<<6|e[1]&63;break;case 3:r=(e[0]&15)<<12|(e[1]&63)<<6|e[2]&63;break;case 4:r=(e[0]&7)<<18|(e[1]&63)<<12|(e[2]&63)<<6|e[3]&63;break}return r===null||r>1114111||r>=55296&&r<=57343||r<(t>3?65536:t>2?2048:t>1?128:0)?null:r},Xh=function(e){return e.length===2?e:kr},Jh=function(e){for(var r=e.length,t="",n=0;n<r;){var i=an(e,n);if(i==="%"){if(an(e,n+1)==="%"||n+3>r){t+="%",n++;continue}var a=uo(e,n+1);if(a!==a){t+=i,n++;continue}n+=2;var s=Yh(a);if(s===0)i=Bh(a);else{if(s===1||s>4){t+=kr,n++;continue}for(var l=[a],u=1;u<s&&(n++,!(n+3>r||an(e,n)!=="%"));){var d=uo(e,n+1);if(d!==d||d>191||d<128||u===1&&(a===224&&d<160||a===237&&d>159||a===240&&d<144||a===244&&d>143))break;Hh(l,d),n+=2,u++}if(l.length!==s){t+=kr;continue}var p=Zh(l);if(p===null){for(var c=0;c<s;c++)t+=kr;n++;continue}else i=jh(p)}}t+=i,n++}return t},Qh=function(e){try{return lo(e)}catch{return lo(zh(e,Vh,Xh))}};co.exports={decode:Jh,encode:Qh}});var Ir=f((S1,po)=>{"use strict";o();var fo=Kt(),ev=Y();po.exports=function(e,r,t){return t.get&&fo(t.get,r,{getter:!0}),t.set&&fo(t.set,r,{setter:!0}),ev.f(e,r,t)}});var vo=f((E1,ho)=>{"use strict";o();var rv=Q();ho.exports=function(e,r,t){for(var n in r)rv(e,n,r[n],t);return e}});var on=f((I1,go)=>{"use strict";o();var tv=pt(),nv=TypeError;go.exports=function(e,r){if(tv(r,e))return e;throw new nv("Incorrect invocation")}});var bo=f((T1,mo)=>{"use strict";o();var iv=ge(),av=k();mo.exports=function(e){if(iv(e)==="Function")return av(e)}});var Pr=f(($1,yo)=>{"use strict";o();var xo=bo(),sv=sr(),ov=er(),lv=xo(xo.bind);yo.exports=function(e,r){return sv(e),r===void 0?e:ov?lv(e,r):function(){return e.apply(r,arguments)}}});var qo=f((A1,So)=>{"use strict";o();var uv=N(),cv=uv("toStringTag"),wo={};wo[cv]="z";So.exports=String(wo)==="[object z]"});var Rr=f((L1,Eo)=>{"use strict";o();var dv=qo(),fv=I(),Tr=ge(),pv=N(),hv=pv("toStringTag"),vv=Object,gv=Tr((function(){return arguments})())==="Arguments",mv=function(e,r){try{return e[r]}catch{}};Eo.exports=dv?Tr:function(e){var r,t,n;return e===void 0?"Undefined":e===null?"Null":typeof(t=mv(r=vv(e),hv))=="string"?t:gv?Tr(r):(n=Tr(r))==="Object"&&fv(r.callee)?"Arguments":n}});var re=f((_1,ko)=>{"use strict";o();var bv=Rr(),xv=String;ko.exports=function(e){if(bv(e)==="Symbol")throw new TypeError("Cannot convert a Symbol value to a string");return xv(e)}});var $r=f((D1,To)=>{"use strict";o();var yv=ge(),wv=rr(),Io=or(),Sv=N(),Po=Sv("iterator"),qv=Array.prototype;To.exports=function(e){if(!wv(e))return Io(e,Po)||Io(e,"@@iterator")||(yv(e)==="Arguments"?qv[Po]:void 0)}});var ln=f((B1,Ro)=>{"use strict";o();var Ev=H(),kv=I(),Iv=J(),Pv=vt(),Tv=$r(),Rv=TypeError;Ro.exports=function(e,r){var t=arguments.length<2?Tv(e):r;if(kv(t))return Iv(Ev(t,e));throw new Rv(Pv(e)+" is not iterable")}});var ue=f((U1,$o)=>{"use strict";o();var $v=TypeError;$o.exports=function(e,r){if(e<r)throw new $v("Not enough arguments");return e}});var un=f((z1,Oo)=>{"use strict";o();var Ov=k();Oo.exports=Ov([].slice)});var Lo=f((K1,Co)=>{"use strict";o();var Ao=un(),Av=Math.floor,cn=function(e,r){var t=e.length;if(t<8)for(var n=1,i,a;n<t;){for(a=n,i=e[n];a&&r(e[a-1],i)>0;)e[a]=e[--a];a!==n++&&(e[a]=i)}else for(var s=Av(t/2),l=cn(Ao(e,0,s),r),u=cn(Ao(e,s),r),d=l.length,p=u.length,c=0,h=0;c<d||h<p;)e[c+h]=c<d&&h<p?r(l[c],u[h])<=0?l[c++]:u[h++]:c<d?l[c++]:u[h++];return e};Co.exports=cn});var bn=f((V1,rl)=>{"use strict";o();Qs();var vn=ae(),Cv=R(),gn=to(),Or=H(),Z=k(),He=P(),Ko=je(),Wo=sn(),Vo=Q(),Lv=Ir(),Fv=vo(),_v=De(),Nv=en(),mn=we(),Yo=on(),dn=I(),Dv=_(),Mv=Pr(),Bv=Rr(),jv=J(),Zo=V(),A=re(),Uv=Le(),Fo=ye(),_o=ln(),Hv=$r(),Ar=qr(),Se=ue(),zv=N(),Gv=Lo(),Kv=zv("iterator"),Ee="URLSearchParams",Xo=Ee+"Iterator",Jo=mn.set,D=mn.getterFor(Ee),Wv=mn.getterFor(Xo),Vv=Wo.decode,Yv=Wo.encode,No=gn("fetch"),Lr=gn("Request"),ze=gn("Headers"),fn=Lr&&Lr.prototype,Do=ze&&ze.prototype,Zv=Cv.TypeError,Xv=Z("".charAt),Mo=Z([].join),ce=Z([].push),Qo=Z("".replace),Jv=Z([].shift),Bo=Z([].splice),jo=Z("".split),Qv=Z("".slice),eg=/\+/g,Uo=function(e){return Vv(Qo(e,eg," "))},rg=/[!'()~]|%20/g,tg={"!":"%21","'":"%27","(":"%28",")":"%29","~":"%7E","%20":"+"},ng=function(e){return tg[e]},Ho=function(e){return Qo(Yv(e),rg,ng)},pn=Nv(function(r,t){Jo(this,{type:Xo,target:D(r).entries,index:0,kind:t})},Ee,function(){var r=Wv(this),t=r.target,n=r.index++;if(!t||n>=t.length)return r.target=null,Ar(void 0,!0);var i=t[n];switch(r.kind){case"keys":return Ar(i.key,!1);case"values":return Ar(i.value,!1)}return Ar([i.key,i.value],!1)},!0),el=function(e){this.entries=[],this.url=null,e!==void 0&&(Zo(e)?this.parseObject(e):this.parseQuery(typeof e=="string"?Xv(e,0)==="?"?Qv(e,1):e:A(e)))};el.prototype={type:Ee,bindURL:function(e){this.url=e,this.update()},parseObject:function(e){var r=this.entries,t=Hv(e),n,i,a,s,l,u,d;if(t)for(n=_o(e,t),i=n.next;!(a=Or(i,n)).done;){if(s=_o(jv(a.value)),l=s.next,(u=Or(l,s)).done||(d=Or(l,s)).done||!Or(l,s).done)throw new Zv("Expected sequence with length 2");ce(r,{key:A(u.value),value:A(d.value)})}else for(var p in e)Dv(e,p)&&ce(r,{key:p,value:A(e[p])})},parseQuery:function(e){if(e)for(var r=this.entries,t=jo(e,"&"),n=0,i,a;n<t.length;)i=t[n++],i.length&&(a=jo(i,"="),ce(r,{key:Uo(Jv(a)),value:Uo(Mo(a,"="))}))},serialize:function(){for(var e=this.entries,r=[],t=0,n;t<e.length;)n=e[t++],ce(r,Ho(n.key)+"="+Ho(n.value));return Mo(r,"&")},update:function(){this.entries.length=0,this.parseQuery(this.url.query)},updateURL:function(){this.url&&this.url.update()}};var Fr=function(){Yo(this,qe);var r=arguments.length>0?arguments[0]:void 0,t=Jo(this,new el(r));He||(this.size=t.entries.length)},qe=Fr.prototype;Fv(qe,{append:function(r,t){var n=D(this);Se(arguments.length,2),ce(n.entries,{key:A(r),value:A(t)}),He||this.size++,n.updateURL()},delete:function(e){for(var r=D(this),t=Se(arguments.length,1),n=r.entries,i=A(e),a=t<2?void 0:arguments[1],s=a===void 0?a:A(a),l=0;l<n.length;){var u=n[l];u.key===i&&(s===void 0||u.value===s)?Bo(n,l,1):l++}He||(this.size=n.length),r.updateURL()},get:function(r){var t=D(this).entries;Se(arguments.length,1);for(var n=A(r),i=0;i<t.length;i++)if(t[i].key===n)return t[i].value;return null},getAll:function(r){var t=D(this).entries;Se(arguments.length,1);for(var n=A(r),i=[],a=0;a<t.length;a++)t[a].key===n&&ce(i,t[a].value);return i},has:function(r){for(var t=D(this).entries,n=Se(arguments.length,1),i=A(r),a=n<2?void 0:arguments[1],s=a===void 0?a:A(a),l=0;l<t.length;){var u=t[l++];if(u.key===i&&(s===void 0||u.value===s))return!0}return!1},set:function(r,t){var n=D(this);Se(arguments.length,2);for(var i=n.entries,a=!1,s=A(r),l=A(t),u=0,d;u<i.length;u++)d=i[u],d.key===s&&(a?Bo(i,u--,1):(a=!0,d.value=l));a||ce(i,{key:s,value:l}),He||(this.size=i.length),n.updateURL()},sort:function(){var r=D(this);Gv(r.entries,function(t,n){return t.key>n.key?1:-1}),r.updateURL()},forEach:function(r){for(var t=D(this).entries,n=Mv(r,arguments.length>1?arguments[1]:void 0),i=0,a;i<t.length;)a=t[i++],n(a.value,a.key,this)},keys:function(){return new pn(this,"keys")},values:function(){return new pn(this,"values")},entries:function(){return new pn(this,"entries")}},{enumerable:!0});Vo(qe,Kv,qe.entries,{name:"entries"});Vo(qe,"toString",function(){return D(this).serialize()},{enumerable:!0});He&&Lv(qe,"size",{get:function(){return D(this).entries.length},configurable:!0,enumerable:!0});_v(Fr,Ee);vn({global:!0,constructor:!0,forced:!Ko},{URLSearchParams:Fr});!Ko&&dn(ze)&&(zo=Z(Do.has),Go=Z(Do.set),hn=function(e){if(Zo(e)){var r=e.body,t;if(Bv(r)===Ee)return t=e.headers?new ze(e.headers):new ze,zo(t,"content-type")||Go(t,"content-type","application/x-www-form-urlencoded;charset=UTF-8"),Uv(e,{body:Fo(0,A(r)),headers:Fo(0,t)})}return e},dn(No)&&vn({global:!0,enumerable:!0,dontCallGetSet:!0,forced:!0},{fetch:function(r){return No(r,arguments.length>1?hn(arguments[1]):{})}}),dn(Lr)&&(Cr=function(r){return Yo(this,fn),new Lr(r,arguments.length>1?hn(arguments[1]):{})},fn.constructor=Cr,Cr.prototype=fn,vn({global:!0,constructor:!0,dontCallGetSet:!0,forced:!0},{Request:Cr})));var zo,Go,hn,Cr;rl.exports={URLSearchParams:Fr,getState:D}});var tl=f(()=>{"use strict";o();bn()});var sl=f(()=>{"use strict";o();var ig=Q(),_r=k(),nl=re(),ag=ue(),al=URLSearchParams,Nr=al.prototype,sg=_r(Nr.append),il=_r(Nr.delete),og=_r(Nr.forEach),lg=_r([].push),xn=new al("a=1&a=2&b=3");xn.delete("a",1);xn.delete("b",void 0);xn+""!="a=2"&&ig(Nr,"delete",function(e){var r=arguments.length,t=r<2?void 0:arguments[1];if(r&&t===void 0)return il(this,e);var n=[];og(this,function(d,p){lg(n,{key:p,value:d})}),ag(r,1);for(var i=nl(e),a=nl(t),s=0,l=n.length,u;s<l;)u=n[s],il(this,u.key),s++;for(s=0;s<l;)u=n[s++],u.key===i&&u.value===a||sg(this,u.key,u.value)},{enumerable:!0,unsafe:!0})});var cl=f(()=>{"use strict";o();var ug=Q(),ll=k(),cg=re(),dg=ue(),ul=URLSearchParams,yn=ul.prototype,fg=ll(yn.getAll),pg=ll(yn.has),ol=new ul("a=1");(ol.has("a",2)||!ol.has("a",void 0))&&ug(yn,"has",function(r){var t=arguments.length,n=t<2?void 0:arguments[1];if(t&&n===void 0)return pg(this,r);var i=fg(this,r);dg(t,1);for(var a=cg(n),s=0;s<i.length;)if(i[s++]===a)return!0;return!1},{enumerable:!0,unsafe:!0})});var dl=f(()=>{"use strict";o();var hg=P(),vg=k(),gg=Ir(),wn=URLSearchParams.prototype,mg=vg(wn.forEach);hg&&!("size"in wn)&&gg(wn,"size",{get:function(){var r=0;return mg(this,function(){r++}),r},configurable:!0,enumerable:!0})});var Sn=f((lw,fl)=>{"use strict";o();var bg=R();fl.exports=bg});var qn=f((cw,pl)=>{"use strict";o();tl();sl();cl();dl();var xg=Sn();pl.exports=xg.URLSearchParams});var kn=f((fw,gl)=>{"use strict";o();var En=k(),yg=ur(),wg=re(),Sg=Oe(),qg=En("".charAt),hl=En("".charCodeAt),Eg=En("".slice),vl=function(e){return function(r,t){var n=wg(Sg(r)),i=yg(t),a=n.length,s,l;return i<0||i>=a?e?"":void 0:(s=hl(n,i),s<55296||s>56319||i+1===a||(l=hl(n,i+1))<56320||l>57343?e?qg(n,i):s:e?Eg(n,i,i+2):(s-55296<<10)+(l-56320)+65536)}};gl.exports={codeAt:vl(!1),charAt:vl(!0)}});var yl=f(()=>{"use strict";o();var kg=kn().charAt,Ig=re(),bl=we(),Pg=tn(),ml=qr(),xl="String Iterator",Tg=bl.set,Rg=bl.getterFor(xl);Pg(String,"String",function(e){Tg(this,{type:xl,string:Ig(e),index:0})},function(){var r=Rg(this),t=r.string,n=r.index,i;return n>=t.length?ml(void 0,!0):(i=kg(t,n),r.index+=i.length,ml(i,!1))})});var El=f((mw,ql)=>{"use strict";o();var wl=P(),$g=k(),Og=H(),Ag=O(),In=Tt(),Cg=Wt(),Lg=Nt(),Fg=Ce(),_g=Qr(),ke=Object.assign,Sl=Object.defineProperty,Ng=$g([].concat);ql.exports=!ke||Ag(function(){if(wl&&ke({b:1},ke(Sl({},"a",{enumerable:!0,get:function(){Sl(this,"b",{value:3,enumerable:!1})}}),{b:2})).b!==1)return!0;var e={},r={},t=Symbol("assign detection"),n="abcdefghijklmnopqrst";return e[t]=7,n.split("").forEach(function(i){r[i]=i}),ke({},e)[t]!==7||In(ke({},r)).join("")!==n})?function(r,t){for(var n=Fg(r),i=arguments.length,a=1,s=Cg.f,l=Lg.f;i>a;)for(var u=_g(arguments[a++]),d=s?Ng(In(u),s(u)):In(u),p=d.length,c=0,h;p>c;)h=d[c++],(!wl||Og(l,u,h))&&(n[h]=u[h]);return n}:ke});var Pn=f((xw,Il)=>{"use strict";o();var Dg=H(),kl=J(),Mg=or();Il.exports=function(e,r,t){var n,i;kl(e);try{if(n=Mg(e,"return"),!n){if(r==="throw")throw t;return t}n=Dg(n,e)}catch(a){i=!0,n=a}if(r==="throw")throw t;if(i)throw n;return kl(n),t}});var Tl=f((ww,Pl)=>{"use strict";o();var Bg=J(),jg=Pn();Pl.exports=function(e,r,t,n){try{return n?r(Bg(t)[0],t[1]):r(t)}catch(i){jg(e,"throw",i)}}});var $l=f((qw,Rl)=>{"use strict";o();var Ug=N(),Hg=Fe(),zg=Ug("iterator"),Gg=Array.prototype;Rl.exports=function(e){return e!==void 0&&(Hg.Array===e||Gg[zg]===e)}});var _l=f((kw,Fl)=>{"use strict";o();var Kg=k(),Wg=O(),Ol=I(),Vg=Rr(),Yg=ie(),Zg=Ht(),Al=function(){},Cl=Yg("Reflect","construct"),Tn=/^\s*(?:class|function)\b/,Xg=Kg(Tn.exec),Jg=!Tn.test(Al),Ge=function(r){if(!Ol(r))return!1;try{return Cl(Al,[],r),!0}catch{return!1}},Ll=function(r){if(!Ol(r))return!1;switch(Vg(r)){case"AsyncFunction":case"GeneratorFunction":case"AsyncGeneratorFunction":return!1}try{return Jg||!!Xg(Tn,Zg(r))}catch{return!0}};Ll.sham=!0;Fl.exports=!Cl||Wg(function(){var e;return Ge(Ge.call)||!Ge(Object)||!Ge(function(){e=!0})||e})?Ll:Ge});var Dl=f((Pw,Nl)=>{"use strict";o();var Qg=P(),em=Y(),rm=ye();Nl.exports=function(e,r,t){Qg?em.f(e,r,rm(0,t)):e[r]=t}});var Bl=f((Rw,Ml)=>{"use strict";o();var tm=ge();Ml.exports=Array.isArray||function(r){return tm(r)==="Array"}});var Ul=f((Ow,jl)=>{"use strict";o();var nm=P(),im=Bl(),am=TypeError,sm=Object.getOwnPropertyDescriptor,om=nm&&!(function(){if(this!==void 0)return!0;try{Object.defineProperty([],"length",{writable:!1}).length=1}catch(e){return e instanceof TypeError}})();jl.exports=om?function(e,r){if(im(e)&&!sm(e,"length").writable)throw new am("Cannot set read only .length");return e.length=r}:function(e,r){return e.length=r}});var zl=f((Cw,Hl)=>{"use strict";o();var lm=TypeError,um=9007199254740991;Hl.exports=function(e){if(e>um)throw new lm("Maximum allowed index exceeded");return e}});var Yl=f((Fw,Vl)=>{"use strict";o();var cm=Pr(),dm=H(),fm=Ce(),pm=Tl(),hm=$l(),vm=_l(),gm=kt(),Gl=Dl(),mm=Ul(),bm=ln(),xm=$r(),Kl=Pn(),ym=zl(),Wl=Array;Vl.exports=function(r){var t=vm(this),n=arguments.length,i=n>1?arguments[1]:void 0,a=i!==void 0;a&&(i=cm(i,n>2?arguments[2]:void 0));var s=fm(r),l=xm(s),u=0,d,p,c,h,x,w;if(l&&!(this===Wl&&hm(l)))for(p=t?new this:[],h=bm(s,l),x=h.next;!(c=dm(x,h)).done;u++){try{ym(u)}catch(v){Kl(h,"throw",v)}w=a?pm(h,i,[c.value,u],!0):c.value;try{Gl(p,u,w)}catch(v){Kl(h,"throw",v)}}else for(d=gm(s),p=t?new this(d):Wl(d);d>u;u++)w=a?i(s[u],u):s[u],Gl(p,u,w);return mm(p,u),p}});var iu=f((Nw,nu)=>{"use strict";o();var de=k(),Rn=2147483647,Ke=36,eu=1,An=26,wm=38,Sm=700,qm=72,Em=128,km="-",Im=/[^\0-\u007E]/,ru=/[.\u3002\uFF0E\uFF61]/g,Zl="Overflow: input needs wider integers to process",$n=Ke-eu,Xl=RangeError,Pm=de(ru.exec),Ie=Math.floor,On=String.fromCharCode,Jl=de("".charCodeAt),tu=de([].join),se=de([].push),Tm=de("".replace),Rm=de("".split),$m=de("".toLowerCase),Om=function(e){for(var r=[],t=0,n=e.length;t<n;){var i=Jl(e,t++);if(i>=55296&&i<=56319&&t<n){var a=Jl(e,t++);(a&64512)===56320?se(r,((i&1023)<<10)+(a&1023)+65536):(se(r,i),t--)}else se(r,i)}return r},Ql=function(e){return e+22+75*(e<26)},Am=function(e,r,t){var n=0;for(e=t?Ie(e/Sm):e>>1,e+=Ie(e/r);e>$n*An>>1;)e=Ie(e/$n),n+=Ke;return Ie(n+($n+1)*e/(e+wm))},Cm=function(e){var r=[];e=Om(e);var t=e.length,n=Em,i=0,a=qm,s,l;for(s=0;s<e.length;s++)l=e[s],l<128&&se(r,On(l));var u=r.length,d=u;for(u&&se(r,km);d<t;){var p=Rn;for(s=0;s<e.length;s++)l=e[s],l>=n&&l<p&&(p=l);var c=d+1;if(p-n>Ie((Rn-i)/c))throw new Xl(Zl);for(i+=(p-n)*c,n=p,s=0;s<e.length;s++){if(l=e[s],l<n&&++i>Rn)throw new Xl(Zl);if(l===n){for(var h=i,x=Ke;;){var w=x<=a?eu:x>=a+An?An:x-a;if(h<w)break;var v=h-w,m=Ke-w;se(r,On(Ql(w+v%m))),h=Ie(v/m),x+=Ke}se(r,On(Ql(h))),a=Am(i,c,d===u),i=0,d++}}i++,n++}return tu(r,"")};nu.exports=function(e){var r=[],t=Rm(Tm($m(e),ru,"."),"."),n,i;for(n=0;n<t.length;n++)i=t[n],se(r,Pm(Im,i)?"xn--"+Cm(i):i);return tu(r,".")}});var Ru=f(()=>{"use strict";o();yl();var Lm=ae(),Vn=P(),Fm=je(),Yn=R(),au=Pr(),F=k(),jr=Q(),M=Ir(),_m=on(),Ur=_(),Xe=El(),he=Yl(),G=un(),mu=kn().codeAt,su=iu(),bu=sn(),ne=re(),Nm=De(),Dm=ue(),xu=bn(),yu=we(),Mm=yu.set,Hr=yu.getterFor("URL"),Bm=xu.URLSearchParams,jm=xu.getState,Um=bu.decode,Hm=bu.encode,We=Yn.URL,Kn=Yn.TypeError,zr=Yn.parseInt,zm=Math.floor,ou=Math.pow,wu=String.fromCharCode,K=F("".charAt),L=F(/./.exec),Ye=F([].join),Gm=F(1.1.toString),Km=F([].pop),Te=F([].push),Cn=F("".replace),Wm=F([].shift),Su=F("".split),Vm=F("".indexOf),Re=F("".slice),Gr=F("".toLowerCase),Ym=F([].unshift),Zm="Invalid authority",Ln="Invalid scheme",fe="Invalid host",lu="Invalid port",qu=/[a-z]/i,Xm=/[\d+\-.a-z]/i,Wn=/\d/,Eu=/^0x/i,Jm=/^[0-7]+$/,ku=/^\d+$/,Zn=/^[\da-f]+$/i,Qm=/[\u0000-\u0020#%/:<>?@[\\\]^|\u007F]/,eb=/[\0\t\n\r #/:<>?@[\\\]^|]/,rb=/^[\u0000-\u0020]+/,tb=/(^|[^\u0000-\u0020])[\u0000-\u0020]+$/,nb=/[\t\n\r]/g,ib=/[^\u0000-\u007F]/,ab="\xA8\xAF\xB4\xB8\u02D8\u02D9\u02DA\u02DB\u02DC\u02DD\u037A\u0384\u0385\u1FBD\u1FBF\u1FC0\u1FC1\u1FCD\u1FCE\u1FCF\u1FDD\u1FDE\u1FDF\u1FED\u1FEE\u1FFD\u1FFE\u2017\u203E\u2047\u2048\u2049\u2100\u2101\u2105\u2106\u2A74\u309B\u309C\uFC5E\uFC5F\uFC60\uFC61\uFC62\uFC63\uFDFA\uFDFB\uFE13\uFE16\uFE47\uFE48\uFE49\uFE4A\uFE4B\uFE4C\uFE55\uFE56\uFE5F\uFE64\uFE65\uFE68\uFE6A\uFE6B\uFE70\uFE72\uFE74\uFE76\uFE78\uFE7A\uFE7C\uFE7E\uFFE3",B,sb=function(e){return e===173||e===847||e===8203||e===12644||e===65279||e===65440||e>=4447&&e<=4448||e>=6068&&e<=6069||e>=6155&&e<=6159||e>=8288&&e<=8292||e>=8298&&e<=8303||e>=65024&&e<=65039||e>=917760&&e<=917999},ob=function(e){return e===65533||e>=55296&&e<=57343||e>=128&&e<=159||e>=8206&&e<=8207||e>=8232&&e<=8233||e>=8234&&e<=8238||e>=8293&&e<=8297||e>=64976&&e<=65007||(e&65534)===65534||e>=57344&&e<=63743||e>=983040&&e<=1114109},lb=function(e){return e>=65281&&e<=65374?e-65248:e===160||e===5760||e===8239||e===8287||e===12288||e>=8192&&e<=8202||e<=65535&&Vm(ab,wu(e))>-1?32:e},ub=function(e){if(!L(ib,e))return e===""?null:su(e);var r=he(e),t="",n,i,a;for(n=0;n<r.length;n++){if(i=mu(r[n],0),ob(i))return null;sb(i)||(a=lb(i),t+=a===i?r[n]:wu(a))}return t===""?null:su(t)},cb=function(e){var r=Su(e,"."),t,n;if(r[r.length-1]===""){if(r.length===1)return!1;r.length--}return t=r[r.length-1],L(ku,t)?!0:L(Eu,t)?(n=Re(t,2),n===""||!!L(Zn,n)):!1},db=function(e){var r=Su(e,"."),t,n,i,a,s,l,u;if(r.length&&r[r.length-1]===""&&r.length--,t=r.length,t>4)return null;for(n=[],i=0;i<t;i++){if(a=r[i],a==="")return null;if(s=10,a.length>1&&K(a,0)==="0"&&(s=L(Eu,a)?16:8,a=Re(a,s===8?1:2)),a==="")l=0;else{if(!L(s===10?ku:s===8?Jm:Zn,a))return null;l=zr(a,s)}Te(n,l)}for(i=0;i<t;i++)if(l=n[i],i===t-1){if(l>=ou(256,5-t))return null}else if(l>255)return null;for(u=Km(n),i=0;i<n.length;i++)u+=n[i]*ou(256,3-i);return u},fb=function(e){var r=[0,0,0,0,0,0,0,0],t=0,n=null,i=0,a,s,l,u,d,p,c,h=function(){return K(e,i)};if(h()===":"){if(K(e,1)!==":")return;i+=2,t++,n=t}for(;h();){if(t===8)return;if(h()===":"){if(n!==null)return;i++,t++,n=t;continue}for(a=s=0;s<4&&L(Zn,h());)a=a*16+zr(h(),16),i++,s++;if(h()==="."){if(s===0||(i-=s,t>6))return;for(l=0;h();){if(u=null,l>0)if(h()==="."&&l<4)i++;else return;if(!L(Wn,h()))return;for(;L(Wn,h());){if(d=zr(h(),10),u===null)u=d;else{if(u===0)return;u=u*10+d}if(u>255)return;i++}r[t]=r[t]*256+u,l++,(l===2||l===4)&&t++}if(l!==4)return;break}else if(h()===":"){if(i++,!h())return}else if(h())return;r[t++]=a}if(n!==null)for(p=t-n,t=7;t!==0&&p>0;)c=r[t],r[t--]=r[n+p-1],r[n+--p]=c;else if(t!==8)return;return r},pb=function(e){for(var r=null,t=1,n=null,i=0,a=0;a<8;a++)e[a]!==0?(i>t&&(r=n,t=i),n=null,i=0):(n===null&&(n=a),++i);return i>t?n:r},Ve=function(e){var r,t,n,i;if(typeof e=="number"){for(r=[],t=0;t<4;t++)Ym(r,e%256),e=zm(e/256);return Ye(r,".")}if(typeof e=="object"){for(r="",n=pb(e),t=0;t<8;t++)i&&e[t]===0||(i&&(i=!1),n===t?(r+=t?":":"::",i=!0):(r+=Gm(e[t],16),t<7&&(r+=":")));return"["+r+"]"}return e},Kr={},Iu=Xe({},Kr,{" ":1,'"':1,"#":1,"<":1,">":1}),hb=Xe({},Iu,{"'":1}),Pu=Xe({},Kr,{" ":1,'"':1,"<":1,">":1,"`":1}),Tu=Xe({},Pu,{"#":1,"?":1,"{":1,"}":1,"^":1}),Fn=Xe({},Tu,{"/":1,":":1,";":1,"=":1,"@":1,"[":1,"\\":1,"]":1,"^":1,"|":1}),oe=function(e,r){var t=mu(e,0);return t>=32&&t<127&&!Ur(r,e)?e:e==="'"&&Ur(r,e)?"%27":Hm(e)},Dr={ftp:21,file:null,http:80,https:443,ws:80,wss:443},Ze=function(e,r){var t;return e.length===2&&L(qu,K(e,0))&&((t=K(e,1))===":"||!r&&t==="|")},uu=function(e){var r;return e.length>1&&Ze(Re(e,0,2))&&(e.length===2||(r=K(e,2))==="/"||r==="\\"||r==="?"||r==="#")},vb=function(e){return e==="."||Gr(e)==="%2e"},gb=function(e){return e=Gr(e),e===".."||e==="%2e."||e===".%2e"||e==="%2e%2e"},_n={},cu={},Nn={},du={},fu={},Dn={},pu={},hu={},Mr={},Br={},Mn={},Bn={},jn={},Un={},vu={},Hn={},Pe={},X={},gu={},pe={},te={},Xn=function(e,r,t){var n=ne(e),i,a,s;if(r){if(a=this.parse(n),a)throw new Kn(a);this.searchParams=null}else{if(t!==void 0&&(i=new Xn(t,!0)),a=this.parse(n,null,i),a)throw new Kn(a);s=jm(new Bm),s.bindURL(this),this.searchParams=s}};Xn.prototype={type:"URL",parse:function(e,r,t){var n=this,i=r||_n,a=0,s="",l=!1,u=!1,d=!1,p,c,h,x;for(e=ne(e),r||(n.scheme="",n.username="",n.password="",n.host=null,n.port=null,n.path=[],n.query=null,n.fragment=null,n.cannotBeABaseURL=!1,e=Cn(e,rb,""),e=Cn(e,tb,"$1")),e=Cn(e,nb,""),p=he(e);a<=p.length;){switch(c=p[a],i){case _n:if(c&&L(qu,c))s+=Gr(c),i=cu;else{if(r)return Ln;i=Nn;continue}break;case cu:if(c&&L(Xm,c))s+=Gr(c);else if(c===":"){if(r&&(n.isSpecial()!==Ur(Dr,s)||s==="file"&&(n.includesCredentials()||n.port!==null)||n.scheme==="file"&&n.host===""))return;if(n.scheme=s,r){n.isSpecial()&&Dr[n.scheme]===n.port&&(n.port=null);return}s="",n.scheme==="file"?i=Un:n.isSpecial()&&t&&t.scheme===n.scheme?i=du:n.isSpecial()?i=hu:p[a+1]==="/"?(i=fu,a++):(n.cannotBeABaseURL=!0,Te(n.path,""),i=gu)}else{if(r)return Ln;s="",i=Nn,a=0;continue}break;case Nn:if(!t||t.cannotBeABaseURL&&c!=="#")return Ln;if(t.cannotBeABaseURL&&c==="#"){n.scheme=t.scheme,n.path=G(t.path),n.query=t.query,n.fragment="",n.cannotBeABaseURL=!0,i=te;break}i=t.scheme==="file"?Un:Dn;continue;case du:if(c==="/"&&p[a+1]==="/")i=Mr,a++;else{i=Dn;continue}break;case fu:if(c==="/"){i=Br;break}else{i=X;continue}case Dn:if(n.scheme=t.scheme,c===B)n.username=t.username,n.password=t.password,n.host=t.host,n.port=t.port,n.path=G(t.path),n.query=t.query;else if(c==="/"||c==="\\"&&n.isSpecial())i=pu;else if(c==="?")n.username=t.username,n.password=t.password,n.host=t.host,n.port=t.port,n.path=G(t.path),n.query="",i=pe;else if(c==="#")n.username=t.username,n.password=t.password,n.host=t.host,n.port=t.port,n.path=G(t.path),n.query=t.query,n.fragment="",i=te;else{n.username=t.username,n.password=t.password,n.host=t.host,n.port=t.port,n.path=G(t.path),n.path.length&&n.path.length--,i=X;continue}break;case pu:if(n.isSpecial()&&(c==="/"||c==="\\"))i=Mr;else if(c==="/")i=Br;else{n.username=t.username,n.password=t.password,n.host=t.host,n.port=t.port,i=X;continue}break;case hu:if(i=Mr,c!=="/"||p[a+1]!=="/")continue;a++;break;case Mr:if(c!=="/"&&c!=="\\"){i=Br;continue}break;case Br:if(c==="@"){l&&(s="%40"+s),l=!0,h=he(s);for(var w=0;w<h.length;w++){var v=h[w];if(v===":"&&!d){d=!0;continue}var m=oe(v,Fn);d?n.password+=m:n.username+=m}s=""}else if(c===B||c==="/"||c==="?"||c==="#"||c==="\\"&&n.isSpecial()){if(l&&s==="")return Zm;a-=he(s).length+1,s="",i=Mn}else s+=c;break;case Mn:case Bn:if(r&&n.scheme==="file"){i=Hn;continue}else if(c===":"&&!u){if(s==="")return fe;if(r===Bn)return;if(x=n.parseHost(s),x)return x;s="",i=jn}else if(c===B||c==="/"||c==="?"||c==="#"||c==="\\"&&n.isSpecial()){if(n.isSpecial()&&s==="")return fe;if(r&&s===""&&(n.includesCredentials()||n.port!==null))return;if(x=n.parseHost(s),x)return x;if(s="",i=Pe,r)return;continue}else c==="["?u=!0:c==="]"&&(u=!1),s+=c;break;case jn:if(L(Wn,c))s+=c;else if(c===B||c==="/"||c==="?"||c==="#"||c==="\\"&&n.isSpecial()||r){if(s!==""){var g=zr(s,10);if(g>65535)return lu;n.port=n.isSpecial()&&g===Dr[n.scheme]?null:g,s=""}if(r)return;i=Pe;continue}else return lu;break;case Un:if(n.scheme="file",n.host="",c==="/"||c==="\\")i=vu;else if(t&&t.scheme==="file")switch(c){case B:n.host=t.host,n.path=G(t.path),n.query=t.query;break;case"?":n.host=t.host,n.path=G(t.path),n.query="",i=pe;break;case"#":n.host=t.host,n.path=G(t.path),n.query=t.query,n.fragment="",i=te;break;default:n.host=t.host,uu(Ye(G(p,a),""))||(n.path=G(t.path),n.shortenPath()),i=X;continue}else{i=X;continue}break;case vu:if(c==="/"||c==="\\"){i=Hn;break}t&&t.scheme==="file"&&(n.host=t.host,!uu(Ye(G(p,a),""))&&Ze(t.path[0],!0)&&Te(n.path,t.path[0])),i=X;continue;case Hn:if(c===B||c==="/"||c==="\\"||c==="?"||c==="#"){if(!r&&Ze(s))i=X;else if(s===""){if(n.host="",r)return;i=Pe}else{if(x=n.parseHost(s),x)return x;if(n.host==="localhost"&&(n.host=""),r)return;s="",i=Pe}continue}else s+=c;break;case Pe:if(n.isSpecial()){if(i=X,c!=="/"&&c!=="\\")continue}else if(!r&&c==="?")n.query="",i=pe;else if(!r&&c==="#")n.fragment="",i=te;else if(c!==B&&(i=X,c!=="/"))continue;break;case X:if(c===B||c==="/"||c==="\\"&&n.isSpecial()||!r&&(c==="?"||c==="#")){if(gb(s)?(n.shortenPath(),c!=="/"&&!(c==="\\"&&n.isSpecial())&&Te(n.path,"")):vb(s)?c!=="/"&&!(c==="\\"&&n.isSpecial())&&Te(n.path,""):(n.scheme==="file"&&!n.path.length&&Ze(s)&&(n.host!==null&&n.host!==""&&(n.host=""),s=K(s,0)+":"),Te(n.path,s)),s="",n.scheme==="file"&&(c===B||c==="?"||c==="#"))for(;n.path.length>1&&n.path[0]==="";)Wm(n.path);c==="?"?(n.query="",i=pe):c==="#"&&(n.fragment="",i=te)}else s+=oe(c,Tu);break;case gu:c==="?"?(n.query="",i=pe):c==="#"?(n.fragment="",i=te):c!==B&&(c===" "?n.path[0]+=p[a+1]==="?"||p[a+1]==="#"?"%20":" ":n.path[0]+=oe(c,Kr));break;case pe:!r&&c==="#"?(n.fragment="",i=te):c!==B&&(n.query+=oe(c,n.isSpecial()?hb:Iu));break;case te:c!==B&&(n.fragment+=oe(c,Pu));break}a++}},parseHost:function(e){var r,t,n;if(K(e,0)==="["){if(K(e,e.length-1)!=="]"||(r=fb(Re(e,1,-1)),!r))return fe;this.host=r}else if(this.isSpecial()){if(e=ub(Um(e)),e===null||L(Qm,e))return fe;if(cb(e)){if(r=db(e),r===null)return fe;this.host=r}else this.host=e}else{if(L(eb,e))return fe;for(r="",t=he(e),n=0;n<t.length;n++)r+=oe(t[n],Kr);this.host=r}},cannotHaveUsernamePasswordPort:function(){return this.host===null||this.host===""||this.cannotBeABaseURL||this.scheme==="file"},includesCredentials:function(){return this.username!==""||this.password!==""},isSpecial:function(){return Ur(Dr,this.scheme)},shortenPath:function(){var e=this.path,r=e.length;r&&(this.scheme!=="file"||r!==1||!Ze(e[0],!0))&&e.length--},serialize:function(){var e=this,r=e.scheme,t=e.username,n=e.password,i=e.host,a=e.port,s=e.path,l=e.query,u=e.fragment,d=r+":";return i!==null?(d+="//",e.includesCredentials()&&(d+=t+(n?":"+n:"")+"@"),d+=Ve(i),a!==null&&(d+=":"+a)):r==="file"&&(d+="//"),i===null&&!e.cannotBeABaseURL&&s.length>1&&s[0]===""&&(d+="/."),d+=e.cannotBeABaseURL?s[0]:s.length?"/"+Ye(s,"/"):"",l!==null&&(d+="?"+l),u!==null&&(d+="#"+u),d},setHref:function(e){var r=this.parse(e);if(r)throw new Kn(r);this.searchParams.update()},getOrigin:function(){var e=this.scheme,r=this.port;if(e==="blob")try{return new $e(this.path[0]).origin}catch{return"null"}return e==="file"||!this.isSpecial()?"null":e+"://"+Ve(this.host)+(r!==null?":"+r:"")},getProtocol:function(){return this.scheme+":"},setProtocol:function(e){this.parse(ne(e)+":",_n)},getUsername:function(){return this.username},setUsername:function(e){var r=he(ne(e));if(!this.cannotHaveUsernamePasswordPort()){this.username="";for(var t=0;t<r.length;t++)this.username+=oe(r[t],Fn)}},getPassword:function(){return this.password},setPassword:function(e){var r=he(ne(e));if(!this.cannotHaveUsernamePasswordPort()){this.password="";for(var t=0;t<r.length;t++)this.password+=oe(r[t],Fn)}},getHost:function(){var e=this.host,r=this.port;return e===null?"":r===null?Ve(e):Ve(e)+":"+r},setHost:function(e){this.cannotBeABaseURL||this.parse(e,Mn)},getHostname:function(){var e=this.host;return e===null?"":Ve(e)},setHostname:function(e){this.cannotBeABaseURL||this.parse(e,Bn)},getPort:function(){var e=this.port;return e===null?"":ne(e)},setPort:function(e){this.cannotHaveUsernamePasswordPort()||(e=ne(e),e===""?this.port=null:this.parse(e,jn))},getPathname:function(){var e=this.path;return this.cannotBeABaseURL?e[0]:e.length?"/"+Ye(e,"/"):""},setPathname:function(e){this.cannotBeABaseURL||(this.path=[],this.parse(e,Pe))},getSearch:function(){var e=this.query;return e?"?"+e:""},setSearch:function(e){e=ne(e),e===""?this.query=null:(K(e,0)==="?"&&(e=Re(e,1)),this.query="",this.parse(e,pe)),this.searchParams.update()},getSearchParams:function(){return this.searchParams.facade},getHash:function(){var e=this.fragment;return e?"#"+e:""},setHash:function(e){if(e=ne(e),e===""){this.fragment=null;return}K(e,0)==="#"&&(e=Re(e,1)),this.fragment="",this.parse(e,te)},update:function(){this.query=this.searchParams.serialize()||null}};var $e=function(r){var t=_m(this,C),n=Dm(arguments.length,1)>1?arguments[1]:void 0,i=Mm(t,new Xn(r,!1,n));Vn||(t.href=i.serialize(),t.origin=i.getOrigin(),t.protocol=i.getProtocol(),t.username=i.getUsername(),t.password=i.getPassword(),t.host=i.getHost(),t.hostname=i.getHostname(),t.port=i.getPort(),t.pathname=i.getPathname(),t.search=i.getSearch(),t.searchParams=i.getSearchParams(),t.hash=i.getHash())},C=$e.prototype,j=function(e,r){return{get:function(){return Hr(this)[e]()},set:r&&function(t){return Hr(this)[r](t)},configurable:!0,enumerable:!0}};Vn&&(M(C,"href",j("serialize","setHref")),M(C,"origin",j("getOrigin")),M(C,"protocol",j("getProtocol","setProtocol")),M(C,"username",j("getUsername","setUsername")),M(C,"password",j("getPassword","setPassword")),M(C,"host",j("getHost","setHost")),M(C,"hostname",j("getHostname","setHostname")),M(C,"port",j("getPort","setPort")),M(C,"pathname",j("getPathname","setPathname")),M(C,"search",j("getSearch","setSearch")),M(C,"searchParams",j("getSearchParams")),M(C,"hash",j("getHash","setHash")));jr(C,"toJSON",function(){return Hr(this).serialize()},{enumerable:!0});jr(C,"toString",function(){return Hr(this).serialize()},{enumerable:!0});We&&(zn=We.createObjectURL,Gn=We.revokeObjectURL,zn&&jr($e,"createObjectURL",au(zn,We)),Gn&&jr($e,"revokeObjectURL",au(Gn,We)));var zn,Gn;Nm($e,"URL");Lm({global:!0,constructor:!0,forced:!Fm,sham:!Vn},{URL:$e})});var $u=f(()=>{"use strict";o();Ru()});var Cu=f(()=>{"use strict";o();var mb=ae(),bb=ie(),Au=O(),xb=ue(),Ou=re(),yb=je(),Jn=bb("URL"),wb=yb&&Au(function(){Jn.canParse()}),Sb=Au(function(){return Jn.canParse.length!==1});mb({target:"URL",stat:!0,forced:!wb||Sb},{canParse:function(r){var t=xb(arguments.length,1),n=Ou(r),i=t<2||arguments[1]===void 0?void 0:Ou(arguments[1]);try{return!!new Jn(n,i)}catch{return!1}}})});var Fu=f(()=>{"use strict";o();var qb=ae(),Eb=ie(),kb=ue(),Lu=re(),Ib=je(),Pb=Eb("URL");qb({target:"URL",stat:!0,forced:!Ib},{parse:function(r){var t=kb(arguments.length,1),n=Lu(r),i=t<2||arguments[1]===void 0?void 0:Lu(arguments[1]);try{return new Pb(n,i)}catch{return null}}})});var Nu=f((Xw,_u)=>{"use strict";o();var Tb=R();_u.exports=function(e,r){var t=Tb[e],n=t&&t.prototype;return n&&n[r]}});var Du=f(()=>{"use strict";o();var Rb=ae(),$b=H(),Ob=Nu(),Ab=Ob("URL","toString");Rb({target:"URL",proto:!0,enumerable:!0},{toJSON:function(){return $b(Ab,this)}})});var Bu=f((tS,Mu)=>{"use strict";o();qn();$u();Cu();Fu();Du();var Cb=Sn();Mu.exports=Cb.URL});var iS,aS,o=ic(()=>{iS=ri(Bu(),1),aS=ri(qn(),1)});var l0={};ac(l0,{PAGE_SCRIPT:()=>Ju,RENDERER_VERSION:()=>e0,renderPublishedPage:()=>o0});o();o();var Je=/^foreverlm:\/\//i,Lb=/^foreverlm:\/\/doc\/([^/?#\s]+)$/i,Fb=/^foreverlm:\/\/attachment\//i,Wr=/^(https?:|mailto:|#)/i,_b=/^https:/i,Nb="https://app.foreverlm.com/",Qn=/^(\d{1,3})(?:\s*[–—-]\s*(\d{1,3}))?\.\s+(.+?)\s*$/,Db=/^\*\*([^*\n]{2,90}?)\*\*(?:\\)?\s+(\S.*)$/,ju=/^(\d{1,3})\.\s+([^·\n]{1,80}?)\.?\s*$/,Mb=/^(\d{1,3})\.\s+([^·\n.]{1,80}?)(?:\.\s+(\S.*))?\.?\s*$/,Uu=/^ {0,3}\[\^([^\][\s]+)\]:\s*(.*)$/,Bb=/\[\^([^\][\s]+)\]/g,Hu=/(`+)(?:[^`]|[^`][\s\S]*?[^`])\1(?!`)|\[\^([^\][\s]+)\]/g,zu=/^\s{0,3}(`{3,}|~{3,})/,jb=/^\s{0,3}(?:#{1,6}\s|>|`{3,}|~{3,}|(?:-{3,}|\*{3,}|_{3,})\s*$|<!--fl\s*\{)|^\s*(?:[-*+]|\d{1,9}[.)])\s+\S/;function S(e){return e.replace(/[&<>"']/g,r=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"})[r])}function T(e){return S(e)}function Gu(e,r){let t=e.toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g,"").replace(/[^a-z0-9\s-]/g,"").trim().replace(/[\s-]+/g,"-").slice(0,64)||"section",n=t,i=2;for(;r.has(n);)n=`${t}-${i++}`;return r.add(n),n}function Vr(e){try{return new URL(e).hostname.replace(/^www\./,"")}catch{return""}}var Ub=/^https?:\/\/(?:[^/?#]*\.)?(?:doi\.org\/|arxiv\.org\/(?:abs|pdf)\/|(?:bio|med|chem)rxiv\.org\/content\/|ssrn\.com\/abstract=|papers\.ssrn\.com\/|pubmed\.ncbi\.nlm\.nih\.gov\/\d|ncbi\.nlm\.nih\.gov\/pmc\/articles\/|europepmc\.org\/(?:article|abstract)\/|nature\.com\/articles\/|science\.org\/doi\/|cell\.com\/[^/?#]+\/fulltext\/|thelancet\.com\/journals\/[^/?#]+\/article\/|nejm\.org\/doi\/|jamanetwork\.com\/journals\/[^/?#]+\/(?:fullarticle|article-abstract)\/|bmj\.com\/content\/|pnas\.org\/doi\/|sciencedirect\.com\/science\/article\/|link\.springer\.com\/(?:article|chapter)\/|onlinelibrary\.wiley\.com\/doi\/|pubs\.acs\.org\/doi\/|academic\.oup\.com\/[^/?#]+\/article\/|journals\.plos\.org\/[^/?#]+\/article|frontiersin\.org\/(?:articles|journals)\/|mdpi\.com\/\d|elifesciences\.org\/articles\/|semanticscholar\.org\/paper\/|openreview\.net\/(?:forum|pdf)|aclanthology\.org\/[^/?#]+|proceedings\.(?:neurips\.cc|mlr\.press)\/|papers\.nips\.cc\/paper|ieeexplore\.ieee\.org\/document\/|dl\.acm\.org\/doi\/)/i,Hb=/^https?:\/\/(?:[^/?#]*\.)?(?:podcasts\.apple\.com\/|open\.spotify\.com\/(?:episode|show)\/|overcast\.fm\/|pca\.st\/|pocketcasts\.com\/|castro\.fm\/|podbean\.com\/|buzzsprout\.com\/|anchor\.fm\/)/i,zb=/^https?:\/\/(?:[^/?#]*\.)?(?:youtube\.com\/(?:watch|live|shorts|embed)|youtu\.be\/|vimeo\.com\/\d|ted\.com\/talks\/)/i,Gb=/^https?:\/\/[^/?#]+\/(?:[^/?#]+\/)*(?:blog|news|posts?|articles?|stories|story|p)\/[^/?#]+/i;function Kb(e,r){let t=e.toLowerCase();return/\b(?:paper|preprint|study|review|trial|publication|manuscript|abstract|poster|thesis|dissertation|monograph)\b/.test(t)?"paper":/\b(?:podcast|episode)\b/.test(t)?"podcast":/\b(?:video|talk|keynote|webinar|lecture|presentation|fireside)\b/.test(t)?"video":/\.pdf(?:$|[?#])/i.test(r)||Ub.test(r)?"paper":Hb.test(r)?"podcast":zb.test(r)?"video":/\b(?:article|blog|post|essay|interview|news|newsletter|op-ed|column|transcript|book|chapter)\b/.test(t)||Gb.test(r)?"article":null}function Wb(e,r,t){let n=new URL(Nb);return n.searchParams.set("add",e),r&&n.searchParams.set("title",r.slice(0,500)),n.searchParams.set("type",t),n.toString()}function Ku(e,r){let t=new RegExp(`(?<=[A-Za-z)\\u00C0-\\u024F])${r}$`);return e.replace(t,"").trim()}function Wu(e){let r=Qn.exec(e);if(!r)return e;let t=parseInt(r[1],10);return`${r[1]}${r[2]?`\u2013${r[2]}`:""}. ${Ku(r[3],t)}`}function Yr(e){return e.replace(/\s+/g," ").trim().toLowerCase()}function Vb(e){let r=e.slice(),t=[],n=new Map,i=l=>l.search(/\S/),a=null,s=0;for(;s<e.length;){let l=e[s];if(a){a.test(l)&&(a=null),s+=1;continue}let u=zu.exec(l);if(u){a=new RegExp(`^\\s{0,3}${u[1][0]==="`"?"`":"~"}{${u[1].length},}\\s*$`),s+=1;continue}let d=Uu.exec(l);if(!d){s+=1;continue}let p=s,c=[d[2]],h=null,x=v=>{if(h){h.test(v)&&(h=null);return}let m=zu.exec(v);m&&(h=new RegExp(`^\\s{0,3}${m[1][0]==="`"?"`":"~"}{${m[1].length},}\\s*$`))};for(x(c[0]),s+=1;s<e.length;){let v=e[s];if(v.trim()===""){let g=s;for(;g<e.length&&e[g].trim()==="";)g+=1;if(g<e.length&&i(e[g])>=4){for(;s<g;s+=1)c.push("");continue}break}if(i(v)>=4){c.push(v.slice(4)),x(c[c.length-1]),s+=1;continue}let m=c[c.length-1];if(!h&&m.trim()!==""&&!Uu.test(v)&&!jb.test(v)){c.push(v.trim()),s+=1;continue}break}for(let v=p;v<s;v+=1)r[v]="";let w=Yr(d[1]);if(!n.has(w)){let v={key:w,body:c,start:p,end:s};t.push(v),n.set(w,v)}}return{lines:r,definitions:t,byKey:n}}function Yb(e=[]){return{lines:e,definitions:[],byKey:new Map}}function Zb(){return{profiles:[],sets:[],sources:[]}}function Xb(e){let r=e.replace(/\s+/g," ").trim(),t=/^(.{20,}?[.!?])(?:\s|$)/.exec(r),n=t?t[1]:r;return n.length>180?`${n.slice(0,177).trimEnd()}\u2026`:n}function Jb(e){let{headings:r}=e,t=new Set,n=r.map(v=>Gu(Wu(v.text),t)),i=[],a=[],s=new Map,l=null;r.forEach((v,m)=>{let g=Qn.exec(v.text),b=g!==null&&(l===null||v.level<=l.level);if(l&&v.level<=l.level&&!(b&&v.level===l.level)&&(l=null),!b||!g)return;let y=parseInt(g[1],10),q=g[2]?parseInt(g[2],10):y,E={headingIndex:m,id:n[m],level:v.level,label:`${y}${q!==y?`\u2013${q}`:""}`,first:y,last:q,name:Ku(g[3],y),summary:Xb(e.facetLeads.get(m)??""),attributes:[],sources:[]};if(!l){let W="";for(let ve=m-1;ve>=0;ve-=1)if(r[ve].level<v.level){W=r[ve].text;break}let $={id:`directory-${a.length+1}`,title:W,profiles:[],filters:[]};a.push($),l={level:v.level,set:$}}l.set.profiles.push(E),i.push(E),s.set(m,E)});for(let v of a.filter(m=>m.profiles.length<3)){for(let m of v.profiles)i.splice(i.indexOf(m),1),s.delete(m.headingIndex);a.splice(a.indexOf(v),1)}a.forEach((v,m)=>{v.id=`directory-${m+1}`});let u=new Map,d=null;r.forEach((v,m)=>{let g=s.get(m);if(g){d=g,u.set(m,g);return}if(d&&v.level>d.level){u.set(m,d);return}d=null});let p=v=>u.get(v)??null,c=[],h=new Set,x=0;for(let v of e.cards){let m=p(v.headingIndex),g;if(m){if(m.sources.find(q=>q.url===v.url))continue;g=`src-${m.first}-${m.sources.length+1}`}else x+=1,g=`src-${x}`;let b={id:g,url:v.url,title:v.title,kind:v.kind,note:v.note,libraryType:v.libraryType};m&&m.sources.push(b),h.has(v.url)||(h.add(v.url),c.push(b))}let w=v=>{let m=v.replace(/^#/,""),g=i.find(q=>q.id===m);if(g)return g;let b=/^(\d{1,3})(?:-|$)/.exec(m);if(!b)return null;let y=parseInt(b[1],10);return i.find(q=>q.first<=y&&y<=q.last)??null};for(let v of e.tables){let m=v.rows.map(b=>{let y=b.find(q=>q.anchor&&w(q.anchor));return y?w(y.anchor):null}),g=m.filter(Boolean).length;g===0||g*2<v.rows.length||v.rows.forEach((b,y)=>{let q=m[y];q&&b.forEach((E,W)=>{let $=(v.headers[W]??"").trim();!$||$==="#"||E.anchor||!E.text.trim()||/^\d{1,3}$/.test(E.text.trim())||q.attributes.some(ve=>ve.label===$)||q.attributes.push({label:$,value:E.text.trim()})})})}for(let v of e.enumerations){let m=r[v.headingIndex];if(!m)continue;let g="Group";for(let b=v.headingIndex-1;b>=0;b-=1)if(r[b].level<m.level){g=r[b].text;break}for(let b of v.items){let y=i.find(q=>q.first<=b.number&&b.number<=q.last);!y||y.attributes.some(q=>q.label===g)||y.attributes.push({label:g,value:m.text})}}for(let v of a){let m=new Map;for(let g of v.profiles)for(let b of g.attributes)m.has(b.label)||m.set(b.label,new Set),m.get(b.label)?.add(b.value);for(let[g,b]of m)b.size>=2&&b.size<=12&&v.filters.push({label:g,values:[...b]})}return{profiles:i,sets:a,sources:c}}function Qb(e,r,t){let n=` data-src="${r}-${t}"`,i=e.indexOf('<header class="profile-head"');if(i>=0){let l=e.indexOf(">",i);return`${e.slice(0,l)}${n}${e.slice(l)}`}let a=/<([a-z][a-z0-9]*)((?:\s[^>]*)?)>/g,s;for(;(s=a.exec(e))!==null;){let[l,u,d]=s;if(u==="section")continue;if(u==="dl"&&/class="facets"/.test(d)||/\sdata-src=/.test(d))return e;let p=s.index+l.length-1;return`${e.slice(0,p)}${n}${e.slice(p)}`}return e}var Zr=class{headings=[];links=[];words=0;deck="";collected={headings:this.headings,facetLeads:new Map,cards:[],tables:[],enumerations:[]};headingIDs=new Set;linkSet=new Set;headingCount=0;currentProfile=null;openProfile=null;surveyProfile=null;profileByHeading=new Map;setStarts=new Map;cardsByURL=new Map;looseCards=0;sawParagraph=!1;noteOrder=[];noteNumbers=new Map;noteCitations=new Map;inNotes=!1;index;drawing;sourceOffset;docLinks;footnotes;constructor(r,t,n=null,i={},a=Yb()){this.index=r,this.drawing=t,this.sourceOffset=n,this.docLinks=i,this.footnotes=a;for(let s of r.profiles)this.profileByHeading.set(s.headingIndex,s);for(let s of r.sets)s.profiles.length>0&&this.setStarts.set(s.profiles[0].headingIndex,s)}render(r){let t=this.renderBlocks(r,this.sourceOffset);this.openProfile&&(t+=`
</section>`,this.openProfile=null),t=t.replace(/<\/dl>\n<dl class="facets">/g,""),t=t.replace(/(<\/a>)[;,]\s*(?=<a class="cite")/g,"$1");let n=this.drawing?this.renderNotes():"";return n&&(t=t?`${t}
${n}`:n),t}get inProfile(){return this.drawing?this.currentProfile:null}get readingProfile(){return this.drawing?this.currentProfile!==null:this.surveyProfile!==null}renderBlocks(r,t=null){let n=[],i=0,a=(s,l,u)=>{n.push(t===null?s:Qb(s,t+l,t+u))};for(;i<r.length;){let s=r[i];if(s.trim()===""){i+=1;continue}let l=i,u=/^\s{0,3}(`{3,}|~{3,})\s*([^`\s]*)/.exec(s);if(u){let[h,x]=[u[1].length,u[2]],w=u[1][0],v=[];for(i+=1;i<r.length;){if(new RegExp(`^\\s{0,3}${w==="`"?"`":"~"}{${h},}\\s*$`).test(r[i])){i+=1;break}v.push(r[i]),i+=1}let m=/^[A-Za-z0-9_+-]{1,32}$/.test(x)?` class="language-${T(x)}"`:"";a(`<pre><code${m}>${S(v.join(`
`))}
</code></pre>`,l,i);continue}if(/^\s{0,3}<!--fl\s*\{[^\n]*\}\s*-->\s*$/.test(s)){i+=1;continue}let d=/^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/.exec(s);if(d){a(this.renderHeading(d[1].length,d[2]),l,i+1),i+=1;continue}if(/^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$/.test(s)){a("<hr>",l,i+1),i+=1;continue}if(/^\s{0,3}>/.test(s)){let h=[];for(;i<r.length&&(/^\s{0,3}>/.test(r[i])||r[i].trim()!==""&&h.length>0&&!this.startsBlock(r[i]));)h.push(r[i].replace(/^\s{0,3}>\s?/,"").replace(/^(\s*)\\\|/,"$1|")),i+=1;a(`<blockquote>${this.renderBlocks(h)}</blockquote>`,l,i);continue}let p=this.listMarker(s);if(p){let[h,x]=this.renderList(r,i,p.ordered,p.indent,t);a(h,l,x),i=x;continue}if(i+1<r.length&&s.includes("|")&&this.isTableDelimiter(r[i+1])){let[h,x]=this.renderTable(r,i);a(h,l,x),i=x;continue}let c=[s];for(i+=1;i<r.length&&r[i].trim()!==""&&!this.startsBlock(r[i])&&!(i+1<r.length&&r[i].includes("|")&&this.isTableDelimiter(r[i+1]));){if(c.length===1&&/^\s{0,3}(=+|-+)\s*$/.test(r[i])){let h=r[i].trim().startsWith("=")?1:2;a(this.renderHeading(h,c[0].trim()),l,i+1),c.length=0,i+=1;break}c.push(r[i]),i+=1}c.length>0&&a(this.renderParagraph(c,t===null?null:t+l),l,i)}return n.filter(s=>s!=="").join(`
`)}startsBlock(r){return/^\s{0,3}(#{1,6}\s|>|(`{3,}|~{3,}))/.test(r)||/^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$/.test(r)||this.listMarker(r)!==null}listMarker(r){let t=/^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/.exec(r);return!t||t[3].trim()===""&&!/\S/.test(t[3])||/\d/.test(t[2])&&/\s·\s\d{1,3}\.\s/.test(t[3])?null:{ordered:/\d/.test(t[2]),indent:t[1].length,content:t[3],width:t[1].length+t[2].length+1}}renderList(r,t,n,i,a=null){let s=[],l=[],u=t,d=null;for(;u<r.length;){let g=this.listMarker(r[u]);if(g&&g.indent===i&&g.ordered===n){n&&d===null&&(d=parseInt(r[u].trim(),10));let b=u,y=[g.content],q=g.width;for(u+=1;u<r.length;){let E=r[u];if(E.trim()===""){if(u+1<r.length&&/^\s+/.test(r[u+1])&&r[u+1].search(/\S/)>=q){y.push(""),u+=1;continue}break}let W=this.listMarker(E);if(W&&W.indent<=i)break;if(E.search(/\S/)>=q||W){y.push(E.slice(Math.min(q,E.search(/\S/)))),u+=1;continue}if(!this.startsBlock(E)){y.push(E.trim()),u+=1;continue}break}s.push(y),l.push([b,u]);continue}break}if(!this.inNotes&&n&&s.length===1&&d!==null&&d!==1&&s[0].length===1&&ju.test(`${d}. ${s[0][0]}`)&&!/[.;:]\s/.test(s[0][0])){let g=s[0][0].trim().replace(/\.$/,"");this.collected.enumerations.push({headingIndex:this.headingCount-1,items:[{number:d,name:g}]});let b=this.drawing?this.index.profiles.find(y=>y.first<=d&&d<=y.last):null;if(b)return[`<p class="enumeration"><a class="chip" href="#${b.id}"><span class="num">${d}</span>${this.renderInline(this.withoutNoteReferences(g))}</a></p>`,u]}let p=n&&d!==null&&d!==1?` start="${d}"`:"",c=s.map(g=>this.renderListItem(g)),h=c.length>0&&c.every(g=>g.startsWith('<div class="source"')),x=h?"ul":n?"ol":"ul",w=h?' class="sources"':"",v=c.map((g,b)=>`<li${a===null?"":` data-src="${a+l[b][0]}-${a+l[b][1]}"`}>${g}</li>`).join(`
`),m=`<${x}${h?w:p}>
${v}
</${x}>`;return h&&this.drawing&&this.currentProfile?[`<details class="sources"><summary>Sources <span class="count">${c.length}</span></summary>
${m}
</details>`,u]:[m,u]}renderListItem(r){let t=r[0],n="",i=/^\[([ xX])\]\s+(.*)$/.exec(t);i&&(n=i[1]===" "?'<span class="task" aria-label="To do">\u2610</span> ':'<span class="task done" aria-label="Done">\u2611</span> ',t=i[2]);let a=r.slice(1);if(!a.some(c=>c.trim()===""||this.startsBlock(c)||this.listMarker(c))){let c=[t,...a].join(`
`),h=n||this.inNotes?null:this.labelledSourceCard(c)??this.referenceCard(c);return h||n+this.renderInline(c)}let l=[t],u=0;for(;u<a.length&&a[u].trim()!==""&&!this.startsBlock(a[u])&&!this.listMarker(a[u]);)l.push(a[u]),u+=1;let d=l.join(`
`);return`${(n||this.inNotes?null:this.labelledSourceCard(d)??this.referenceCard(d))??n+this.renderInline(d)}
${this.renderBlocks(a.slice(u))}`}isTableDelimiter(r){return/^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/.test(r)&&r.includes("-")&&r.includes("|")}splitRow(r){let t=r.trim();t.startsWith("|")&&(t=t.slice(1)),t.endsWith("|")&&!t.endsWith("\\|")&&(t=t.slice(0,-1));let n=[],i="";for(let a=0;a<t.length;a+=1){let s=t[a];if(s==="\\"&&t[a+1]==="|"){i+="|",a+=1;continue}if(s==="|"){n.push(i.trim()),i="";continue}i+=s}return n.push(i.trim()),n}renderTable(r,t){let n=this.splitRow(r[t]),i=this.splitRow(r[t+1]).map(v=>{let m=v.startsWith(":"),g=v.endsWith(":");return m&&g?"center":g?"right":m?"left":""}),a=t+2,s=[];for(;a<r.length&&r[a].trim()!==""&&r[a].includes("|")&&!this.startsBlock(r[a]);)s.push(this.splitRow(r[a])),a+=1;let l=v=>/^(?:\s|<br\s*\/?>)*$/i.test(v),u=n.map((v,m)=>s.length>0&&s.every(g=>l(g[m]??"")||/^[\d.,%+−-]+$/.test((g[m]??"").trim()))),d=(v,m,g,b="")=>{let y=i[g]??"";y==="right"&&!u[g]&&(y="");let q=y?` style="text-align:${y}"`:"",E=v==="td"&&n[g]?` data-label="${T(this.plainText(n[g]))}"`:"";return`<${v}${q}${E}${b}>${this.renderInline(m)}</${v}>`},p=`<thead><tr>${n.map((v,m)=>d("th",v,m)).join("")}</tr></thead>`,c=[],h=[];for(let v of s){let m=n.map((b,y)=>!l(v[y]??"")),g=m.filter(Boolean).length;if(g!==0){if(g===1&&n.length>1){let b=m.indexOf(!0);c.push(`<tr class="note"><td colspan="${n.length}">${this.renderInline(v[b])}</td></tr>`);continue}c.push(`<tr>${n.map((b,y)=>d("td",v[y]??"",y)).join("")}</tr>`),h.push(n.map((b,y)=>{let q=v[y]??"",E=/^\[[^\]]+\]\(\s*(#[^\s)]+)\s*\)$/.exec(q.trim());return{text:this.plainText(q),anchor:E?E[1]:null}}))}}this.collected.tables.push({headingIndex:this.headingCount-1,headers:n.map(v=>this.plainText(v)),rows:h});let x=c.length>0?`<tbody>${c.join("")}</tbody>`:"";return[`<div class="table-scroll${n.length>=3?" wide":""}"><table>${p}${x}</table></div>`,a]}renderHeading(r,t){if(this.inNotes)return`<h${r}>${this.renderInline(t)}</h${r}>`;let n=this.headingCount;this.headingCount+=1;let i=this.drawing?this.profileByHeading.get(n)??null:null,a=this.drawing?Wu(t):t,s=this.plainText(a),l=Gu(s,this.headingIDs);if(this.headings.push({level:r,id:l,text:s}),!this.drawing)return Qn.test(t)?this.surveyProfile={headingIndex:n,level:r}:(!this.surveyProfile||r<=this.surveyProfile.level)&&(this.surveyProfile=null),`<h${r} id="${l}">${this.renderInline(a)}</h${r}>`;let u=[];if(this.openProfile&&(i||r<=this.openProfile.level)&&(u.push("</section>"),this.openProfile=null),i){let d=this.setStarts.get(n);d&&u.push(this.renderDirectory(d)),this.currentProfile=i,this.openProfile=i,u.push(`<section class="profile" id="${l}" data-number="${i.first}">`);let p=this.noteLabelsIn(t).map(c=>this.noteReference(c)??"").join("");return u.push(`<header class="profile-head"><span class="num" aria-hidden="true">${S(i.label)}</span><h${r}>${this.renderInline(i.name)}${p}</h${r}><a class="up" href="#${this.setFor(i)?.id??l}">Directory</a></header>`),u.join(`
`)}return(!this.currentProfile||r<=this.currentProfile.level)&&(this.currentProfile=null),u.push(`<h${r} id="${l}">${this.renderInline(a)}</h${r}>`),u.join(`
`)}setFor(r){return this.index.sets.find(t=>t.profiles.includes(r))??null}renderDirectory(r){let t=r.profiles.map(a=>{let s=a.attributes.map(d=>`<span class="attr" data-label="${T(d.label)}">${S(d.value)}</span>`).join(""),l=a.summary?`<span class="dir-summary">${S(a.summary)}</span>`:"",u=a.sources.length>0?`<span class="dir-sources">${a.sources.length} ${a.sources.length===1?"source":"sources"}</span>`:"";return`<a class="dir-card" href="#${a.id}" data-search="${T(`${a.name} ${a.attributes.map(d=>d.value).join(" ")} ${a.summary}`.toLowerCase())}"><span class="num">${S(a.label)}</span><span class="dir-name">${this.renderInline(a.name)}</span>${s?`<span class="dir-attrs">${s}</span>`:""}${l}${u}</a>`}).join(`
`),n=r.filters.map(a=>`<div class="dir-filter" data-label="${T(a.label)}"><span class="dir-filter-label">${S(a.label)}</span>${a.values.map(s=>`<button type="button" class="chip" data-value="${T(s)}">${S(s)}</button>`).join("")}</div>`).join(""),i=r.profiles.length;return`<section class="directory" id="${r.id}" aria-label="${T(r.title||"Directory")}"><div class="dir-tools" hidden><input type="search" class="dir-search" placeholder="Filter ${i} ${i===1?"profile":"profiles"}\u2026" aria-label="Filter profiles">${n}<span class="dir-count"></span></div><div class="dir-grid">
${t}
</div></section>`}facets(r){let t=[];for(let n=0;n<r.length;n+=1){let i=Db.exec(r[n].trim());if(i)t.push({label:i[1].replace(/[.:]\s*$/,"").trim(),text:i[2],from:n,to:n+1});else if(t.length>0){let a=t[t.length-1];a.text+=`
${r[n].trim()}`,a.to=n+1}else return null}return t.length===0||!this.readingProfile&&t.length<2?null:t}renderParagraph(r,t=null){let n=r.map(d=>d.trim()).join(`
`),i=!this.sawParagraph;this.sawParagraph=!0;let a=this.inNotes?null:this.sourceCard(n)??this.labelledSourceCard(n)??this.referenceCard(n);if(a)return a;let s=this.inNotes?null:this.enumeration(n);if(s)return s;let l=this.inNotes?null:this.facets(r);if(l){let d=this.drawing?this.currentProfile?.headingIndex:this.surveyProfile?.headingIndex;return d!==void 0&&!this.collected.facetLeads.has(d)&&this.collected.facetLeads.set(d,this.plainText(l[0].text)),`<dl class="facets">${l.map(c=>{let h=/question/i.test(c.label)?" question":"",x=t===null?"":` data-src="${t+c.from}-${t+c.to}"`;return`<div class="facet${h}"${x}><dt>${this.renderInline(c.label)}</dt><dd>${this.renderInline(c.text)}</dd></div>`}).join("")}</dl>`}let u=/^!\[([^\]]*)\]\(\s*<?([^\s>]+)>?(?:\s+"([^"]*)")?\s*\)$/.exec(n);if(u){let d=this.renderImage(u[1],u[2],u[3]);if(d==="")return"";let p=u[3]?`<figcaption>${S(u[3])}</figcaption>`:"";return`<figure>${d}${p}</figure>`}return i&&!this.inNotes&&this.headingCount<=1&&r.every(d=>/^\*\*[^*]+\*\*\\?$/.test(d.trim()))?(this.deck=r.map(d=>this.renderInline(d.trim().replace(/^\*\*|\*\*\\?$/g,""))).join(`<br>
`),""):`<p>${this.renderInline(n)}</p>`}enumeration(r){let n=r.replace(/\s*\n\s*/g," ").trim().split(/\s+·\s+/);if(n.length<2)return null;let i=[],a="";if(n.forEach((u,d)=>{if(i.length!==d)return;let p=d===n.length-1,c=(p?Mb:ju).exec(u.trim());c&&(i.push({number:parseInt(c[1],10),name:c[2]}),p&&c[3]&&(a=c[3]))}),i.length!==n.length)return null;this.collected.enumerations.push({headingIndex:this.headingCount-1,items:i});let s=i.map(u=>{let d=this.drawing?this.index.profiles.find(c=>c.first<=u.number&&u.number<=c.last):null,p=`<span class="num">${u.number}</span>${this.renderInline(d?this.withoutNoteReferences(u.name):u.name)}`;return d?`<a class="chip" href="#${d.id}">${p}</a>`:`<span class="chip">${p}</span>`}),l=a?`
<p>${this.renderInline(a)}</p>`:"";return`<p class="enumeration">${s.join("")}</p>${l}`}card(r,t,n,i){let a=Vr(r);this.noteLink(r);let s=Kb(n,r);if(this.collected.cards.push({headingIndex:this.headingCount-1,url:r,title:this.plainText(t),kind:n,note:this.plainText(i),libraryType:s}),!this.drawing)return`<div class="source">${S(t)}</div>`;let l,u=this.currentProfile?.sources.find(h=>h.url===r);u?this.cardsByURL.has(`${this.currentProfile?.id}:${r}`)?l="":(l=u.id,this.cardsByURL.set(`${this.currentProfile?.id}:${r}`,u)):(this.looseCards+=1,l=`src-${this.looseCards}`);let d=[n,i].filter(h=>h.trim()!==""),p=d.length>0?`<span class="ref-detail">${d.map((h,x)=>x===0&&n?S(h):this.renderInline(h)).join(" \xB7 ")}</span>`:"",c=u&&this.currentProfile?`<span class="ref-n" aria-hidden="true">${this.currentProfile.sources.indexOf(u)+1}</span>`:"";return`<div class="source"${l?` id="${l}"`:""}><a class="ref-card" href="${T(r)}" rel="noopener noreferrer" target="_blank">${c}<span class="ref-title">${this.renderInline(t)}</span>`+p+`<span class="ref-site">${S(a)}</span></a>`+(s?`<a class="add" href="${T(Wb(r,this.plainText(t),s))}" target="_blank" rel="noopener" title="Add to your ForeverLM library"><span class="add-mark" aria-hidden="true">+</span><span class="add-label">Add to library</span></a>`:"")+"</div>"}referenceCard(r){let t=/^\[([^\]\n]+)\]\(\s*<?([^\s>]+)>?(?:\s+"[^"]*")?\s*\)(?:\s*(?:[—–-]|:)\s*([^\n]{1,200}))?$/.exec(r.trim());if(!t||this.noteLabelsIn(r).length>0)return null;let[,n,i,a]=t;return Je.test(i)||!Wr.test(i)||i.startsWith("#")||!Vr(i)?null:this.card(i,n,"",a??"")}labelledSourceCard(r){let t=/^\*\*([^*\n]{1,80}?):?\*\*:?\s+\[([^\]\n]+)\]\(\s*<?([^\s>]+)>?(?:\s+"[^"]*")?\s*\)\.?\s*([^\n]{0,300})$/.exec(r.trim());if(!t||this.noteLabelsIn(r).length>0)return null;let[,n,i,a,s]=t;if(Je.test(a)||!Wr.test(a)||a.startsWith("#")||!Vr(a))return null;let l=n.split(/\s*·\s*/),u=(l.length>1?l[l.length-1]:/^[A-Z]\d+-[A-Z]\d+$/.test(l[0])?"":l[0]).trim();return this.card(a,i,u,s.trim())}sourceCard(r){let t=r.trim().split(`
`);if(t.length!==2)return null;let n=/^\*\*\[?(?:＋\s*Add to Sources|✓\s*In Sources)(?:\s*·\s*([^*\]]+?))?\]?(?:\([^)]*\))?\*\*\\?$/.exec(t[0].trim());if(!n)return null;let i=n[1]?.trim()??"",a=/^\[([^\]\n]+)\]\(\s*<?([^\s>]+)>?(?:\s+"[^"]*")?\s*\)$/.exec(t[1].trim());if(!a)return null;let[,s,l]=a;return Je.test(l)||!Wr.test(l)||!Vr(l)?`<p class="ref-plain">${i?`<span class="ref-kind">${S(i)}</span>`:""}${this.renderInline(s)}</p>`:this.card(l,s,i,"")}plainText(r){return this.withoutNoteReferences(r).replace(/!\[([^\]]*)\]\([^)]*\)/g,"$1").replace(/\[([^\]]*)\]\([^)]*\)/g,"$1").replace(/`([^`]+)`/g,"$1").replace(/<br\s*\/?>/gi," ").replace(/(\*\*|__|\*|_|~~)/g,"").trim()}renderInline(r){let t=[],n=s=>(t.push(s),`\0${t.length-1}\0`),i=r;i=i.replace(/(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/g,(s,l,u)=>n(`<code>${S(u.trim())}</code>`)),i=i.replace(/!\[([^\]]*)\]\(\s*<?([^\s>]+)>?(?:\s+"([^"]*)")?\s*\)/g,(s,l,u,d)=>n(this.renderImage(l,u,d))),i=i.replace(/\[([^\]]+)\]\(\s*<?([^\s>]+)>?(?:\s+"([^"]*)")?\s*\)/g,(s,l,u,d)=>n(this.renderLink(l,u,d))),i=i.replace(/<(https?:\/\/[^\s>]+)>/g,(s,l)=>n(this.renderLink(l,l,void 0,!0))),this.footnotes.byKey.size>0&&(i=i.replace(Bb,(s,l)=>{let u=this.noteReference(l);return u===null?s:n(u)})),i=i.replace(/(^|[\s(])((?:https?:\/\/)[^\s<>()\u0000]+[^\s<>().,;:!?'"\u0000])/g,(s,l,u)=>`${l}${n(this.renderLink(u,u,void 0,!0))}`),i=i.replace(/<br\s*\/?>/gi,()=>n("<br>")),this.words+=i.split(/\s+/).filter(s=>/[A-Za-z0-9À-ɏ]/.test(s)).length;let a=S(i);return a=a.replace(/\*\*(?=\S)([\s\S]+?\S)\*\*/g,"<strong>$1</strong>"),a=a.replace(/(^|[^A-Za-z0-9])__(?=\S)([\s\S]+?\S)__(?![A-Za-z0-9])/g,"$1<strong>$2</strong>"),a=a.replace(/\*(?=\S)([^*\n]+?\S)\*/g,"<em>$1</em>"),a=a.replace(/(^|[^A-Za-z0-9])_(?=\S)([^_\n]+?\S)_(?![A-Za-z0-9])/g,"$1<em>$2</em>"),a=a.replace(/~~(?=\S)([\s\S]+?\S)~~/g,"<del>$1</del>"),a=a.replace(/(?: {2,}|\\)\n/g,`<br>
`),a.replace(/ (\d+) /g,(s,l)=>t[Number(l)])}renderLink(r,t,n,i=!1){let a=i?S(r):this.renderInline(r),s=this.docPage(t);if(s)return`<a href="${T(s)}"${n?` title="${T(n)}"`:""}>${a}</a>`;if(Je.test(t)||!Wr.test(t))return a;if(t.startsWith("#")){let p=this.drawing?this.resolveProfileAnchor(t):null;return`<a href="#${T(p?p.id:t.slice(1))}">${a}</a>`}this.noteLink(t);let l=this.inProfile,u=l?.sources.find(p=>p.url===t);if(l&&u){let p=l.sources.indexOf(u)+1;return`<a class="cite" href="#${u.id}" title="${T(u.title)}">${p}</a>`}let d=n?` title="${T(n)}"`:"";return`<a href="${T(t)}"${d} rel="noopener noreferrer" target="_blank">${a}</a>`}docPage(r){let t=Lb.exec(r.trim());if(!t)return null;let n=t[1];try{n=decodeURIComponent(n)}catch{}let i=this.docLinks[n];return typeof i=="string"&&/^https:\/\//i.test(i)?i:null}resolveProfileAnchor(r){let t=r.replace(/^#/,""),n=this.index.profiles.find(s=>s.id===t);if(n)return n;let i=/^(\d{1,3})(?:-|$)/.exec(t);if(!i)return null;let a=parseInt(i[1],10);return this.index.profiles.find(s=>s.first<=a&&a<=s.last)??null}renderImage(r,t,n){if(Fb.test(t)||Je.test(t)||!_b.test(t))return r?`<em class="dropped-image">${S(r)}</em>`:"";let i=n?` title="${T(n)}"`:"";return`<img src="${T(t)}" alt="${T(r)}"${i} loading="lazy">`}noteLink(r){this.linkSet.has(r)||(this.linkSet.add(r),this.links.push(r))}noteLabelsIn(r){if(this.footnotes.byKey.size===0)return[];let t=[];for(let n of r.matchAll(Hu))n[2]!==void 0&&this.footnotes.byKey.has(Yr(n[2]))&&t.push(n[2]);return t}withoutNoteReferences(r){return this.footnotes.byKey.size===0?r:r.replace(Hu,(t,n,i)=>i!==void 0&&this.footnotes.byKey.has(Yr(i))?"":t)}noteReference(r){let t=this.footnotes.byKey.get(Yr(r));if(!t)return null;let n=this.numberNote(t),i=(this.noteCitations.get(t)??0)+1;this.noteCitations.set(t,i);let a=i===1?`fnref-${n}`:`fnref-${n}-${i}`;return`<sup class="fn-ref"><a href="#fn-${n}" id="${a}">${n}</a></sup>`}numberNote(r){let t=this.noteNumbers.get(r);return t!==void 0?t:(this.noteOrder.push(r),this.noteNumbers.set(r,this.noteOrder.length),this.noteOrder.length)}renderNotes(){if(this.footnotes.definitions.length===0)return"";this.inNotes=!0,this.currentProfile=null,this.sawParagraph=!0;let r=[],t=()=>{for(;r.length<this.noteOrder.length;)r.push(this.renderBlocks(this.noteOrder[r.length].body))};t();for(let i of this.footnotes.definitions)this.numberNote(i),t();return this.inNotes=!1,`<section class="footnotes" aria-label="Notes">
<ol>
${this.noteOrder.map((i,a)=>{let s=a+1,l=r[a];if((this.noteCitations.get(i)??0)>0){let d=`<a class="fn-back" href="#fnref-${s}" aria-label="Back to the text">\u21A9</a>`;l.endsWith("</p>")?l=`${l.slice(0,-4)} ${d}</p>`:l=l?`${l}
${d}`:d}let u=this.sourceOffset===null?"":` data-src="${this.sourceOffset+i.start}-${this.sourceOffset+i.end}"`;return`<li id="fn-${s}"${u}>${l}</li>`}).join(`
`)}
</ol>
</section>`}};function Vu(e,r={}){let t=String(e??"").replace(/\r\n?/g,`
`).replace(/\t/g,"    "),n=Vb(t.split(`
`)),i=n.lines,a=new Zr(Zb(),!1,null,{},n);a.render(i);let s=Jb(a.collected),l=new Zr(s,!0,r.sourceOffset??null,r.docLinks??{},n);return{html:l.render(i),headings:l.headings,links:l.links,index:s,words:l.words,deck:l.deck}}function Yu(e,r){let t=String(e??"").replace(/\r\n?/g,`
`).split(`
`),n=0;for(;n<t.length&&t[n].trim()==="";)n+=1;let i=/^\s{0,3}#\s+(.*?)\s*#*\s*$/.exec(t[n]??"");if(i&&i[1].trim().toLowerCase()===r.trim().toLowerCase()){let a=n+1;for(;a<t.length&&t[a]==="";)a+=1;return{markdown:t.slice(a).join(`
`),offset:a}}return{markdown:t.join(`
`),offset:0}}var e0=6,r0='-apple-system,BlinkMacSystemFont,"Helvetica Neue",Helvetica,Arial,sans-serif',t0='"Iowan Old Style","Palatino Linotype",Palatino,Georgia,ui-serif,serif',n0=`
:root{color-scheme:light dark;--page:#f7f7f4;--surface:#fff;--ink:#1f211f;--muted:#555a55;--faint:#7b817b;--line:#dcded8;--accent:#395b52;--accent-soft:#e7eeea;--code:#ecece8;--sans:${r0};--serif:${t0}}
@media (prefers-color-scheme:dark){:root{--page:#131314;--surface:#1b1b1d;--ink:#f3f3f4;--muted:#b2b3b7;--faint:#8a8b90;--line:#2a2a2d;--accent:#8fbfae;--accent-soft:#1d2925;--code:#202023}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;scroll-behavior:smooth}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
body{margin:0;background:var(--page);color:var(--ink);font:17px/1.65 var(--serif);font-feature-settings:"kern","liga"}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
[hidden]{display:none!important}
.page{max-width:1280px;margin:0 auto;padding:0 28px 72px}
.brand{display:flex;align-items:center;gap:8px;padding:22px 0 0;font:600 13px/1 var(--sans);color:var(--muted);text-decoration:none}
.brand img{width:22px;height:22px;border-radius:6px}
.brand:hover{color:var(--ink);text-decoration:none}
header.doc{padding:44px 0 36px;border-bottom:1px solid var(--line);margin-bottom:36px}
header.doc .kicker{margin:0 0 10px;font:600 12px/1.4 var(--sans);letter-spacing:.08em;text-transform:uppercase;color:var(--faint)}
header.doc h1{font-size:clamp(1.9rem,3.4vw,2.7rem);line-height:1.15;letter-spacing:-.015em;margin:0 0 14px;font-weight:600;max-width:900px}
header.doc .deck{margin:0 0 18px;max-width:760px;font:17px/1.5 var(--sans);color:var(--muted)}
header.doc .meta{margin:0;color:var(--faint);font:14px/1.6 var(--sans);display:flex;flex-wrap:wrap;gap:4px 8px;align-items:center}
header.doc .meta a{color:var(--muted);border-bottom:1px solid var(--line)}
header.doc .meta a:hover{color:var(--ink);text-decoration:none}
header.doc .meta .dot{color:var(--line)}
.layout{display:grid;grid-template-columns:minmax(0,1fr);gap:0}
nav.contents{font:14px/1.55 var(--sans);margin:0 0 28px}
nav.contents .label{margin:0 0 8px;color:var(--faint);font-size:11px;letter-spacing:.1em;text-transform:uppercase}
nav.contents ol{list-style:none;margin:0;padding:0}
nav.contents li{margin:0}
nav.contents li a{display:block;padding:4px 0 4px 10px;border-left:2px solid transparent;color:var(--muted)}
nav.contents li a:hover{color:var(--ink);text-decoration:none}
nav.contents li a.current{color:var(--ink);border-left-color:var(--accent)}
nav.contents ol ol{margin:2px 0 6px 10px}
nav.contents ol ol a{font-size:13px}
nav.contents details{margin:2px 0 6px 10px}
nav.contents summary{cursor:pointer;color:var(--faint);font-size:13px;padding:3px 0 3px 10px;list-style:none}
nav.contents summary::-webkit-details-marker{display:none}
nav.contents summary::before{content:"\u25B8";display:inline-block;width:12px;font-size:11px;transition:transform .12s}
nav.contents details[open] summary::before{transform:rotate(90deg)}
nav.contents ol.profiles a{display:grid;grid-template-columns:2.2em minmax(0,1fr);gap:6px;font-size:13px;padding:3px 0 3px 10px}
nav.contents ol.profiles .n{color:var(--faint);font-variant-numeric:tabular-nums;text-align:right}
nav.contents > details.fold > summary{font-size:14px;color:var(--ink);padding:10px 14px;border:1px solid var(--line);border-radius:10px;background:var(--surface)}
nav.contents > details.fold > summary::before{content:none}
nav.contents > details.fold[open] > summary{margin-bottom:12px}
nav.contents > details.fold{margin:0}
article{min-width:0;max-width:920px}
article > p,article > ul:not(.sources),article > ol,article > blockquote,article > h1,article > h2,article > h3,article > h4,article > figure,article > pre,.profile > p,.profile > ul:not(.sources),.profile > ol,.profile > blockquote,.profile > h4{max-width:680px}
article h1,article h2,article h3,article h4{line-height:1.25;letter-spacing:-.01em;font-weight:600;scroll-margin-top:24px}
article h1{font-size:1.75rem;margin:2.6em 0 .6em}
article h2{font-size:1.4rem;margin:2.2em 0 .6em}
article h3{font-size:1.15rem;margin:1.8em 0 .5em}
article h4{font-size:1rem;margin:1.4em 0 .3em;color:var(--muted)}
article > h1:first-child,article > h2:first-child{margin-top:0}
article p{margin:0 0 1.15em}
article ul,article ol{padding-left:1.4em;margin:0 0 1.15em}
article li{margin:.3em 0}
article li>ul,article li>ol{margin:.3em 0 .5em}
article blockquote{margin:1.3em 0;padding:.3em 0 .3em 1.1em;border-left:3px solid var(--accent-soft);color:var(--muted)}
article blockquote:not(:has(> :not(.source,.ref-plain))){border:0;padding:0;margin:0 0 .5em;color:inherit}
article hr{border:0;border-top:1px solid var(--line);margin:2.6em auto;width:120px}
article code{font:.9em ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--code);padding:.1em .35em;border-radius:5px}
article pre{background:var(--code);padding:14px 16px;border-radius:10px;overflow-x:auto;font-size:14px;line-height:1.5;margin:0 0 1.2em}
article pre code{background:none;padding:0;font-size:inherit}
article img{max-width:100%;height:auto;border-radius:8px}
article figure{margin:1.4em 0}
article figcaption{color:var(--muted);font-size:14px;margin-top:6px}
article .dropped-image{color:var(--faint)}
article .task{color:var(--muted)}
article .task.done{color:var(--accent)}
.table-scroll{overflow-x:auto;margin:0 0 1.5em;border:1px solid var(--line);border-radius:12px;background:var(--surface)}
table{border-collapse:collapse;width:100%;font:14px/1.5 var(--sans)}
th,td{padding:10px 14px;border-bottom:1px solid var(--line);vertical-align:top;text-align:left}
tbody tr:last-child td{border-bottom:0}
th{font-weight:600;color:var(--muted);font-size:11px;letter-spacing:.06em;text-transform:uppercase;background:var(--page)}
td:first-child{font-weight:600;min-width:9em}
tr.note td{color:var(--muted);font-size:13px;font-weight:400}
.directory{margin:8px 0 32px}
.dir-tools{display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center;margin:0 0 14px;font:14px/1.4 var(--sans)}
.dir-search{flex:1 1 220px;min-width:0;font:inherit;padding:9px 12px;border:1px solid var(--line);border-radius:10px;background:var(--surface);color:inherit}
.dir-search:focus{outline:2px solid var(--accent);outline-offset:1px}
.dir-filter{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
.dir-filter-label{color:var(--faint);font-size:11px;letter-spacing:.08em;text-transform:uppercase;margin-right:2px}
.dir-count{color:var(--faint);font-size:13px;margin-left:auto}
button.chip{font:inherit;font-size:13px;padding:5px 11px;border:1px solid var(--line);border-radius:999px;background:var(--surface);color:var(--muted);cursor:pointer}
button.chip:hover{border-color:var(--accent);color:var(--ink)}
button.chip[aria-pressed="true"]{background:var(--accent);border-color:var(--accent);color:#fff}
.dir-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:10px}
.dir-card{display:grid;grid-template-columns:auto minmax(0,1fr);gap:4px 10px;align-content:start;padding:14px 16px;border:1px solid var(--line);border-radius:12px;background:var(--surface);color:inherit;text-decoration:none;font:14px/1.45 var(--sans);transition:border-color .12s}
.dir-card:hover{border-color:var(--accent);text-decoration:none}
.dir-card .num{grid-row:1;color:var(--faint);font-weight:600;font-size:12px;padding-top:3px;font-variant-numeric:tabular-nums}
.dir-name{grid-column:2;font-weight:600;font-size:15px}
.dir-attrs,.dir-summary,.dir-sources{grid-column:2}
.dir-attrs .attr{display:inline-block;font-size:12px;color:var(--accent);background:var(--accent-soft);border-radius:6px;padding:2px 7px;margin:2px 4px 2px 0}
.dir-summary{color:var(--muted);font-size:13px}
.dir-sources{color:var(--faint);font-size:12px;margin-top:2px}
.profile{margin:36px 0 0;padding:28px 0 6px;border-top:1px solid var(--line);scroll-margin-top:16px}
.profile-head{display:flex;align-items:baseline;gap:14px;margin:0 0 20px}
.profile-head .num{flex:none;font:600 13px/1 var(--sans);color:var(--accent);background:var(--accent-soft);border-radius:999px;padding:7px 10px;min-width:34px;text-align:center;font-variant-numeric:tabular-nums}
.profile-head h1,.profile-head h2,.profile-head h3,.profile-head h4{margin:0;font-size:1.5rem;line-height:1.2}
.profile-head .up{margin-left:auto;flex:none;font:13px/1 var(--sans);color:var(--faint);white-space:nowrap}
.profile-head .up::before{content:"\u2191 "}
dl.facets{display:grid;grid-template-columns:150px minmax(0,1fr);gap:12px 22px;margin:0 0 1.4em}
dl.facets .facet{display:contents}
dl.facets dt{font:600 11px/1.6 var(--sans);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);padding-top:4px}
dl.facets dd{margin:0;max-width:680px}
dl.facets .facet.question dd{font-style:italic;color:var(--ink);border-left:3px solid var(--accent);padding-left:12px}
a.cite{display:inline-block;font:600 11px/1 var(--sans);color:var(--accent);background:var(--accent-soft);border-radius:6px;padding:3px 5px;margin:0 2px 0 1px;vertical-align:.15em;text-decoration:none;font-variant-numeric:tabular-nums}
a.cite:hover{background:var(--accent);color:#fff;text-decoration:none}
ul.sources{list-style:none;padding:0;margin:6px 0 1.5em;display:grid;gap:8px}
details.sources{margin:6px 0 1.5em}
details.sources > summary{cursor:pointer;list-style:none;display:flex;align-items:center;gap:8px;font:600 11px/1.6 var(--sans);letter-spacing:.08em;text-transform:uppercase;color:var(--muted);padding:6px 0;user-select:none;-webkit-user-select:none}
details.sources > summary::-webkit-details-marker{display:none}
details.sources > summary::before{content:"\u25B8";display:inline-block;width:10px;font-size:11px;letter-spacing:0;transition:transform .12s}
details.sources[open] > summary::before{transform:rotate(90deg)}
details.sources > summary:hover{color:var(--ink)}
details.sources > summary .count{font-weight:500;color:var(--faint);letter-spacing:0;font-variant-numeric:tabular-nums}
details.sources > ul.sources{margin:6px 0 0}
ul.sources li{margin:0}
@media (min-width:980px){ul.sources{grid-template-columns:1fr 1fr}}
.source{display:grid;grid-template-columns:minmax(0,1fr) auto;border:1px solid var(--line);border-radius:12px;background:var(--surface);margin:0 0 8px;scroll-margin-top:16px;transition:border-color .12s}
ul.sources .source,li > .source{margin:0}
.source:hover,.source:target{border-color:var(--accent)}
.source .ref-card{display:grid;grid-template-columns:auto minmax(0,1fr);gap:2px 10px;align-items:baseline;padding:12px 14px;color:inherit;text-decoration:none;font:14px/1.4 var(--sans);min-width:0}
.source .ref-card:hover{text-decoration:none}
.ref-n{grid-row:1/span 3;font:600 12px/1.4 var(--sans);color:var(--faint);font-variant-numeric:tabular-nums;min-width:14px}
.ref-title{font-weight:600;grid-column:2}
.ref-detail{color:var(--muted);grid-column:2;font-size:13px}
.ref-site{color:var(--faint);grid-column:2;font-size:12px}
.source .ref-card:not(:has(.ref-n)) .ref-title,.source .ref-card:not(:has(.ref-n)) .ref-detail,.source .ref-card:not(:has(.ref-n)) .ref-site{grid-column:1/-1}
.source .add{display:flex;align-items:center;gap:7px;padding:0 14px;border-left:1px solid var(--line);font:600 13px/1 var(--sans);color:var(--accent);text-decoration:none;white-space:nowrap;border-radius:0 12px 12px 0}
.source .add:hover{background:var(--accent-soft);text-decoration:none}
.add-mark{display:inline-grid;place-items:center;width:20px;height:20px;border:1.5px solid currentColor;border-radius:50%;font-size:15px;line-height:1;padding-bottom:1px}
.ref-plain{padding:12px 16px;margin:0 0 8px;border:1px dashed var(--line);border-radius:12px;font:14px/1.45 var(--sans)}
.ref-kind{display:block;color:var(--muted);font-size:11px;letter-spacing:.06em;text-transform:uppercase;margin-bottom:2px}
p.enumeration{display:flex;flex-wrap:wrap;gap:6px;font:14px/1.3 var(--sans);max-width:none!important}
.enumeration .chip{display:inline-flex;align-items:center;gap:7px;padding:6px 11px;border:1px solid var(--line);border-radius:999px;background:var(--surface);color:inherit;text-decoration:none}
.enumeration .chip .num{color:var(--faint);font-size:12px;font-weight:600;font-variant-numeric:tabular-nums}
.enumeration a.chip:hover{border-color:var(--accent);text-decoration:none}
sup.fn-ref{font-size:100%;line-height:0;vertical-align:super}
sup.fn-ref a{font:600 .72em/1 var(--sans);font-variant-numeric:tabular-nums;padding:1px 2px;margin-left:1px;border-radius:4px;text-decoration:none;scroll-margin-top:30vh}
sup.fn-ref a:hover,sup.fn-ref a:focus-visible,sup.fn-ref a[aria-describedby],sup.fn-ref a:target{background:var(--accent-soft);text-decoration:none}
section.footnotes{margin:3em 0 0;padding-top:1.4em;border-top:1px solid var(--line);font-size:.92em;line-height:1.6;color:var(--muted);max-width:680px}
section.footnotes ol{margin:0;padding-left:2em}
section.footnotes > ol > li{margin:0 0 .9em;padding-left:.4em;scroll-margin-top:24px}
section.footnotes > ol > li::marker{font:600 .85em var(--sans);font-variant-numeric:tabular-nums;color:var(--faint)}
section.footnotes > ol > li:target{color:var(--ink)}
section.footnotes > ol > li:target::marker{color:var(--accent)}
section.footnotes li p,section.footnotes li ul,section.footnotes li ol{margin:0 0 .6em}
section.footnotes li ul{list-style:disc}
section.footnotes li li{margin:.15em 0}
section.footnotes li > :last-child{margin-bottom:0}
a.fn-back{font:600 .85em/1 var(--sans);color:var(--faint);text-decoration:none}
a.fn-back:hover{color:var(--accent);text-decoration:none}
@media screen{html.fn-cards section.footnotes{display:none}}
.fn-card{position:absolute;z-index:6;max-width:min(360px,calc(100vw - 16px));padding:12px;border:1px solid var(--line);border-radius:10px;background:var(--surface);box-shadow:0 6px 20px rgba(0,0,0,.14);font:15px/1.5 var(--serif);color:var(--ink);text-align:left}
.fn-card p,.fn-card ul,.fn-card ol,.fn-card blockquote,.fn-card pre{margin:0 0 .6em}
.fn-card > :last-child{margin-bottom:0}
.fn-card ul,.fn-card ol{padding-left:1.3em}
.fn-card blockquote{padding-left:.8em;border-left:3px solid var(--accent-soft);color:var(--muted)}
.fn-card code{font:.9em ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--code);padding:.1em .35em;border-radius:5px}
.fn-card pre{overflow-x:auto;background:var(--code);padding:8px 10px;border-radius:8px;font-size:13px}
.fn-card pre code{background:none;padding:0}
.fn-card img{max-width:100%;height:auto;border-radius:6px}
footer.doc{margin-top:64px;padding-top:22px;border-top:1px solid var(--line);color:var(--muted);font:14px/1.6 var(--sans);display:flex;flex-wrap:wrap;gap:8px 24px;justify-content:space-between}
footer.doc a{color:inherit}
footer.doc .mark{font-weight:600;color:var(--ink)}
@media (min-width:1180px){
.layout{grid-template-columns:220px minmax(0,1fr);gap:56px;align-items:start}
nav.contents{position:sticky;top:20px;max-height:calc(100vh - 40px);overflow:auto;padding-right:8px;margin:0;scrollbar-width:thin}
nav.contents > details.fold > summary{display:none}
}
@media (max-width:1179px){
nav.contents ol.profiles{max-height:240px;overflow:auto}
}
@media (max-width:640px){
.page{padding:0 18px 56px}
body{font-size:16px}
header.doc{padding:32px 0 26px}
dl.facets{grid-template-columns:1fr;gap:4px 0}
dl.facets dt{padding-top:14px}
dl.facets .facet:first-child dt{padding-top:0}
.add-label{display:none}
.source .add{padding:0 12px}
.profile-head .up{display:none}
table,thead,tbody,tr,td{display:block}
thead{display:none}
tr{padding:10px 14px;border-bottom:1px solid var(--line)}
tr:last-child{border-bottom:0}
td,tr.note td{border:0;padding:3px 0;min-width:0}
td[data-label]::before{content:attr(data-label);display:block;font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--faint);font-weight:400}
td:first-child{font-size:15px}
}
@media print{
.page{max-width:none;padding:0}
nav.contents,.dir-tools,.source .add,.profile-head .up,.brand,footer.doc,.fn-card,a.fn-back{display:none!important}
.source,.dir-card,.table-scroll{break-inside:avoid;border-color:#bbb}
a{color:inherit}
}
/* Edit mode (PAGE_SCRIPT, ForeverLMPage): inert until a host turns it on. */
.edit-target{outline:1.5px solid var(--accent);outline-offset:6px;border-radius:3px}
.edit-busy{opacity:.55;animation:edit-pulse 1.2s ease-in-out infinite}
@keyframes edit-pulse{50%{opacity:.85}}
.edit-proposed{background:var(--accent-soft);box-shadow:0 0 0 8px var(--accent-soft);border-radius:3px}
.edit-failed{outline:1.5px solid #c0392b;outline-offset:6px;border-radius:3px}
.edit-kept{box-shadow:0 0 0 8px var(--accent-soft);border-radius:3px;transition:box-shadow .6s}
.edit-bubble{position:absolute;z-index:5;display:inline-flex;gap:2px;padding:3px;border:1px solid var(--line);border-radius:999px;background:var(--surface);box-shadow:0 4px 14px rgba(0,0,0,.12);font:600 12px/1.2 var(--sans)}
.edit-bubble button{padding:5px 10px;border:0;border-radius:999px;background:transparent;color:var(--ink);font:inherit;cursor:pointer;white-space:nowrap}
.edit-bubble button.ai{color:var(--accent)}
.edit-bubble button:hover{background:var(--accent-soft)}
.edit-excerpt{flex-basis:100%;margin:0 0 2px;color:var(--muted);font-style:italic;font-size:13px}
.edit-slot{list-style:none;margin:0;padding:0}
.edit-composer,.edit-bar{margin:12px 0 18px;padding:10px 12px;border:1px solid var(--line);border-radius:10px;background:var(--surface);font:14px/1.4 var(--sans);color:var(--ink);max-width:680px}
.edit-composer{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.edit-composer input,.edit-bar input{flex:1 1 220px;min-width:0;padding:7px 10px;border:1px solid var(--line);border-radius:8px;background:var(--page);color:var(--ink);font:inherit}
.edit-composer input:focus,.edit-bar input:focus{outline:2px solid var(--accent);outline-offset:0;border-color:transparent}
.edit-composer button,.edit-bar button{padding:6px 12px;border:1px solid var(--line);border-radius:8px;background:var(--surface);color:var(--ink);font:600 13px/1.2 var(--sans);cursor:pointer}
.edit-composer button:hover,.edit-bar button:hover{border-color:var(--accent)}
.edit-composer button[type=submit],.edit-bar button.keep{background:var(--accent);border-color:var(--accent);color:var(--page)}
.edit-composer .hint,.edit-bar .edit-note{flex-basis:100%;margin:0;color:var(--faint);font-size:12px}
.edit-composer textarea{flex-basis:100%;width:100%;min-height:72px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;background:var(--page);color:var(--ink);font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;resize:vertical}
.edit-composer textarea:focus{outline:2px solid var(--accent);outline-offset:0;border-color:transparent}
.edit-composer .edit-bar-actions{flex-basis:100%}
.edit-bar .edit-note{color:var(--muted);font-size:13px;margin-bottom:8px}
.busy input,.busy button{opacity:.6;pointer-events:none}
.edit-bar-head{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap;margin-bottom:8px}
.edit-bar-title{font-weight:600}
.edit-bar-instruction{color:var(--muted);font-style:italic}
.edit-bar-retry{display:flex;gap:8px;margin:0 0 8px}
.edit-bar-actions{display:flex;gap:8px}
.edit-bar.failed .edit-bar-title{color:#c0392b}
.edit-bar.kept{display:flex;gap:10px;align-items:center;padding:6px 12px}
`.trim(),Ju=`
(function(){
"use strict";
var wide=window.matchMedia("(min-width: 1180px)");
function fitRail(){document.querySelectorAll("nav.contents details.profiles").forEach(function(d){if(wide.matches)d.open=true;});}
fitRail();if(wide.addEventListener)wide.addEventListener("change",fitRail);
document.querySelectorAll(".directory").forEach(function(dir){
  var tools=dir.querySelector(".dir-tools");if(!tools)return;
  tools.hidden=false;
  var search=tools.querySelector(".dir-search");
  var count=tools.querySelector(".dir-count");
  var cards=Array.prototype.slice.call(dir.querySelectorAll(".dir-card"));
  var active={};
  function profileFor(card){var id=card.getAttribute("href").slice(1);return document.getElementById(id);}
  function apply(){
    var q=(search.value||"").trim().toLowerCase();
    var shown=0;
    cards.forEach(function(card){
      var ok=true;
      Object.keys(active).forEach(function(label){
        if(!ok)return;
        var attrs=card.querySelectorAll('.attr[data-label="'+label.replace(/"/g,'\\\\"')+'"]');
        var hit=false;attrs.forEach(function(a){if(a.textContent===active[label])hit=true;});
        ok=hit;
      });
      if(ok&&q){
        var hay=card.getAttribute("data-search")||"";
        var section=profileFor(card);
        if(hay.indexOf(q)<0&&(!section||section.textContent.toLowerCase().indexOf(q)<0))ok=false;
      }
      card.hidden=!ok;
      var section=profileFor(card);if(section)section.hidden=!ok;
      if(ok)shown++;
    });
    var filtering=q||Object.keys(active).length>0;
    count.textContent=filtering?shown+" of "+cards.length:"";
  }
  search.addEventListener("input",apply);
  tools.querySelectorAll("button.chip").forEach(function(chip){
    chip.setAttribute("aria-pressed","false");
    chip.addEventListener("click",function(){
      var label=chip.parentNode.getAttribute("data-label");
      var value=chip.getAttribute("data-value");
      var on=active[label]===value;
      chip.parentNode.querySelectorAll("button.chip").forEach(function(c){c.setAttribute("aria-pressed","false");});
      if(on){delete active[label];}else{active[label]=value;chip.setAttribute("aria-pressed","true");}
      apply();
    });
  });
});
function reveal(id){var el=id?document.getElementById(id):null;if(!el)return null;var d=el.closest("details");while(d){d.open=true;d=d.parentElement?d.parentElement.closest("details"):null;}return el;}
document.addEventListener("click",function(e){var a=e.target&&e.target.closest?e.target.closest("a[href^='#']"):null;if(a)reveal(a.getAttribute("href").slice(1));});
function revealHash(){var el=reveal(location.hash.slice(1));if(el&&el.closest("details"))el.scrollIntoView();}
revealHash();window.addEventListener("hashchange",revealHash);
var links=Array.prototype.slice.call(document.querySelectorAll("nav.contents a[href^='#']"));
if(links.length&&"IntersectionObserver" in window){
  var byID={};links.forEach(function(a){byID[a.getAttribute("href").slice(1)]=a;});
  var visible={};
  var io=new IntersectionObserver(function(entries){
    entries.forEach(function(e){visible[e.target.id]=e.isIntersecting;});
    var ids=Object.keys(byID);var current=null;
    for(var i=0;i<ids.length;i++){var el=document.getElementById(ids[i]);if(!el)continue;if(el.getBoundingClientRect().top<=120)current=ids[i];}
    links.forEach(function(a){a.classList.toggle("current",a.getAttribute("href").slice(1)===current);});
    if(current&&byID[current]&&wide.matches){var r=byID[current].getBoundingClientRect(),n=byID[current].closest("nav");if(n&&(r.top<n.getBoundingClientRect().top||r.bottom>n.getBoundingClientRect().bottom))byID[current].scrollIntoView({block:"nearest"});}
  },{rootMargin:"-10% 0px -60% 0px",threshold:[0,1]});
  Object.keys(byID).forEach(function(id){var el=document.getElementById(id);if(el)io.observe(el);});
}
// Notes. The notes are not printed at the end of the page on screen (product
// owner, 2026-11-07: "those footnotes shouldn't actually be at the bottom;
// only just when i click the superscript then something should show up"):
// where the pointer can hover, resting on a note's number shows the note in a
// card under it, as Substack does, and the card stays while the pointer moves
// into it, so a link in the note can be followed; a click or a tap on the
// number opens the card and keeps it until a click elsewhere or Escape.
// Without this script, and in print, the notes stand at the end as before.
document.documentElement.classList.add("fn-cards");
var canHover=window.matchMedia?window.matchMedia("(hover: hover) and (pointer: fine)"):null;
var note={card:null,link:null,showing:null,hiding:null,pinned:false};
function noteRefOf(node){var el=node&&node.nodeType===1?node:(node?node.parentElement:null);return el&&el.closest?el.closest("sup.fn-ref a"):null;}
function inNoteCard(node){return !!(note.card&&node&&note.card.contains(node));}
function hideNote(){
  clearTimeout(note.showing);clearTimeout(note.hiding);note.showing=null;note.hiding=null;
  if(note.link){note.link.removeAttribute("aria-describedby");note.link=null;}
  note.pinned=false;
  if(note.card)note.card.hidden=true;
}
// Under the number, kept 8px inside the window's sides, above it when the
// window has no room below.
function placeNote(link){
  var card=note.card,r=link.getBoundingClientRect(),gap=6;
  card.style.left="0px";card.style.top="0px";
  var width=card.offsetWidth,height=card.offsetHeight;
  var left=Math.max(8,Math.min(r.left+r.width/2-width/2,document.documentElement.clientWidth-width-8));
  var top=r.bottom+gap;
  if(top+height>window.innerHeight-8&&r.top-gap-height>=8)top=r.top-gap-height;
  card.style.left=(window.scrollX+left)+"px";card.style.top=(window.scrollY+top)+"px";
}
// The card holds a copy of the note, without its way back and without ids,
// which belong to the note itself.
function showNote(link){
  var item=document.getElementById((link.getAttribute("href")||"").slice(1));
  if(!item)return;
  if(!note.card){
    note.card=document.createElement("div");note.card.className="fn-card";note.card.id="fn-card";note.card.setAttribute("role","tooltip");note.card.hidden=true;
    document.body.appendChild(note.card);
  }
  var card=note.card;
  while(card.firstChild)card.removeChild(card.firstChild);
  Array.prototype.forEach.call(item.childNodes,function(child){card.appendChild(child.cloneNode(true));});
  Array.prototype.forEach.call(card.querySelectorAll(".fn-back"),function(a){a.parentNode.removeChild(a);});
  Array.prototype.forEach.call(card.querySelectorAll("[id]"),function(el){el.removeAttribute("id");});
  if(note.link&&note.link!==link)note.link.removeAttribute("aria-describedby");
  note.link=link;link.setAttribute("aria-describedby","fn-card");
  card.hidden=false;
  placeNote(link);
}
document.addEventListener("mouseover",function(e){
  if(!canHover||!canHover.matches)return;
  var link=noteRefOf(e.target);
  if(link||inNoteCard(e.target)){clearTimeout(note.hiding);note.hiding=null;}
  if(!link||(link===note.link&&note.card&&!note.card.hidden))return;
  clearTimeout(note.showing);
  note.showing=setTimeout(function(){note.showing=null;showNote(link);},120);
});
document.addEventListener("mouseout",function(e){
  var from=noteRefOf(e.target)||(inNoteCard(e.target)?note.card:null);
  if(!from)return;
  var to=e.relatedTarget;
  if(to&&(from.contains(to)||inNoteCard(to)||(note.link&&noteRefOf(to)===note.link)))return;
  clearTimeout(note.showing);note.showing=null;
  if(note.pinned)return;
  if(note.card&&!note.card.hidden){clearTimeout(note.hiding);note.hiding=setTimeout(hideNote,150);}
});
document.addEventListener("keydown",function(e){if(e.key==="Escape"&&note.card&&!note.card.hidden)hideNote();});
document.addEventListener("click",function(e){
  var link=noteRefOf(e.target);
  if(link){
    e.preventDefault();
    if(note.pinned&&note.link===link){hideNote();return;}
    clearTimeout(note.showing);clearTimeout(note.hiding);note.showing=null;note.hiding=null;
    showNote(link);note.pinned=true;
    return;
  }
  if(note.card&&!note.card.hidden&&!inNoteCard(e.target))hideNote();
});
// Edit mode. A host that shows the page (the Mac app's Page view, Web Studio's
// frame) turns it on (ForeverLMPage.enableEditing, or a "foreverlm-host"
// message). The page then answers a selection with a bubble, Edit with AI and
// Edit text; puts the instruction field, or the passage's own Markdown, under
// the blocks the selection touches ([data-src], the Markdown lines behind each
// block); and, once the host has re-rendered the page with the proposal in
// place and called review(), draws Keep / Try again / Discard under the
// proposed blocks. Nothing here changes the document: every step is a message
// to the host, which owns the Markdown and the model (docs/docs-design.md,
// Edit with AI, On the page).
var edit={on:false,bubble:null,slot:null,targets:[],range:null,selection:"",busy:false};
function postHost(message){
  try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.foreverLMPage){window.webkit.messageHandlers.foreverLMPage.postMessage(message);return;}}catch(e){}
  if(window.parent&&window.parent!==window){var copy={source:"foreverlm-page"};for(var key in message)copy[key]=message[key];window.parent.postMessage(copy,"*");}
}
function srcOf(el){var v=(el.getAttribute("data-src")||"").split("-");return {start:parseInt(v[0],10),end:parseInt(v[1],10)};}
function markedBlocks(){return Array.prototype.slice.call(document.querySelectorAll("[data-src]"));}
function blocksWithin(start,end){
  return markedBlocks().filter(function(el){
    var r=srcOf(el);if(!(r.start>=start&&r.end<=end))return false;
    var up=el.parentElement?el.parentElement.closest("[data-src]"):null;
    if(!up)return true;var u=srcOf(up);return !(u.start>=start&&u.end<=end);
  });
}
function markOf(node){
  var el=node&&node.nodeType===1?node:(node?node.parentElement:null);
  var m=el&&el.closest?el.closest("[data-src]"):null;
  return m&&m.closest("article, header.doc")?m:null;
}
var SPACES=new RegExp("[ "+String.fromCharCode(9,10,13,160)+"]+","g");
function squash(text){return String(text||"").replace(SPACES," ").trim();}
// What the reader has selected, as the blocks it touches and its words.
function selectedPassage(){
  var sel=window.getSelection();
  if(!sel||sel.isCollapsed||sel.rangeCount<1)return null;
  var range=sel.getRangeAt(0);
  var text=squash(sel.toString());
  if(!text)return null;
  var a=markOf(range.startContainer),b=markOf(range.endContainer);
  if(!a||!b)return null;
  var ra=srcOf(a),rb=srcOf(b);
  var start=Math.min(ra.start,rb.start),end=Math.max(ra.end,rb.end);
  var blocks=blocksWithin(start,end);
  if(!blocks.length)return null;
  var whole=squash(blocks.map(function(el){return el.textContent;}).join(" "));
  return {start:start,end:end,text:text,blocks:blocks,range:range,partial:text!==whole};
}
function clearMarks(){markedBlocks().forEach(function(el){el.classList.remove("edit-target","edit-busy","edit-proposed","edit-failed","edit-kept");});}
function removeSlot(){if(edit.slot&&edit.slot.parentNode)edit.slot.parentNode.removeChild(edit.slot);edit.slot=null;edit.targets=[];edit.range=null;}
function hideBubble(){if(edit.bubble)edit.bubble.hidden=true;}
function placeBubble(range){
  var r=range.getBoundingClientRect();
  if(!r.width&&!r.height){hideBubble();return;}
  edit.bubble.hidden=false;
  var width=edit.bubble.offsetWidth;
  edit.bubble.style.top=(window.scrollY+r.top-edit.bubble.offsetHeight-8)+"px";
  edit.bubble.style.left=Math.max(8,Math.min(window.scrollX+r.left+r.width/2-width/2,window.scrollX+document.documentElement.clientWidth-width-8))+"px";
}
function showBubble(){
  if(!edit.on||edit.slot){hideBubble();return;}
  var passage=selectedPassage();
  if(!passage){hideBubble();return;}
  if(!edit.bubble){
    edit.bubble=document.createElement("div");edit.bubble.className="edit-bubble";edit.bubble.setAttribute("role","toolbar");edit.bubble.setAttribute("aria-label","Edit the selection");
    edit.bubble.innerHTML='<button type="button" class="ai">\u2726 Edit with AI</button><button type="button" class="text">Edit text</button>';
    // A press on the bubble must not take the selection away before it is read.
    edit.bubble.addEventListener("mousedown",function(e){e.preventDefault();});
    edit.bubble.querySelector(".ai").addEventListener("click",function(){var p=selectedPassage();if(p)openComposer(p);});
    edit.bubble.querySelector(".text").addEventListener("click",function(){var p=selectedPassage();if(p)openSource(p);});
    document.body.appendChild(edit.bubble);
  }
  edit.range=passage.range;
  placeBubble(passage.range);
}
function slotAfter(el){var slot=document.createElement(el.tagName==="LI"?"li":"div");slot.className="edit-slot";el.insertAdjacentElement("afterend",slot);return slot;}
function target(passage){
  removeSlot();clearMarks();hideBubble();
  passage.blocks.forEach(function(el){el.classList.add("edit-target");});
  edit.targets=passage.blocks;
  edit.selection=passage.partial?passage.text:"";
  var slot=slotAfter(passage.blocks[passage.blocks.length-1]);edit.slot=slot;
  var sel=window.getSelection();if(sel)sel.removeAllRanges();
  return slot;
}
function excerpt(text){return text.length>140?text.slice(0,138)+"\u2026":text;}
function openComposer(passage){
  var slot=target(passage);
  var form=document.createElement("form");form.className="edit-composer";
  form.innerHTML='<p class="edit-excerpt" hidden></p><input type="text" autocomplete="off" placeholder="Describe the change\u2026" aria-label="Describe the change"><button type="submit">Ask</button><button type="button" class="edit-text">Edit text</button><span class="hint">Return asks the AI \xB7 Edit text changes it yourself \xB7 Esc closes</span>';
  slot.appendChild(form);
  if(edit.selection){var ex=form.querySelector(".edit-excerpt");ex.textContent="\u201C"+excerpt(edit.selection)+"\u201D";ex.hidden=false;}
  var input=form.querySelector("input");
  form.querySelector(".edit-text").addEventListener("click",function(){
    if(edit.busy)return;
    edit.busy=true;form.classList.add("busy");
    postHost({type:"sourceRequested",start:passage.start,end:passage.end});
  });
  form.addEventListener("submit",function(e){
    e.preventDefault();var text=input.value.trim();if(!text||edit.busy)return;
    edit.busy=true;form.classList.add("busy");form.querySelector(".hint").textContent="Rewriting\u2026";
    edit.targets.forEach(function(el){el.classList.remove("edit-target");el.classList.add("edit-busy");});
    var message={type:"editRequested",start:passage.start,end:passage.end,instruction:text};
    if(edit.selection)message.selection=edit.selection;
    postHost(message);
  });
  input.addEventListener("keydown",function(e){if(e.key==="Escape"&&!edit.busy){e.preventDefault();review(null);}});
  input.focus();
}
function openSource(passage){
  var slot=target(passage);
  var form=document.createElement("form");form.className="edit-composer busy";
  form.innerHTML='<span class="hint">Opening the text\u2026</span>';
  slot.appendChild(form);
  edit.busy=true;
  postHost({type:"sourceRequested",start:passage.start,end:passage.end});
}
// The host answering sourceRequested: the passage's own Markdown, to change by
// hand. Save posts the text back; the host writes it as it would a keystroke.
function source(state){
  if(!state||!edit.slot||!edit.targets.length)return;
  var start=Math.min.apply(null,edit.targets.map(function(el){return srcOf(el).start;}));
  var end=Math.max.apply(null,edit.targets.map(function(el){return srcOf(el).end;}));
  if(start!==state.start||end!==state.end)return;
  edit.busy=false;
  while(edit.slot.firstChild)edit.slot.removeChild(edit.slot.firstChild);
  var form=document.createElement("form");form.className="edit-composer edit-source";
  form.innerHTML='<textarea aria-label="The passage as Markdown" spellcheck="true"></textarea><div class="edit-bar-actions"><button type="submit" class="keep">Save</button><button type="button" class="discard">Cancel</button></div><span class="hint">\u2318\u21A9 saves \xB7 Esc cancels \xB7 Markdown, with links kept as written</span>';
  var area=form.querySelector("textarea");
  area.value=String(state.markdown||"");
  area.rows=Math.min(24,Math.max(3,area.value.split(String.fromCharCode(10)).length+1));
  form.addEventListener("submit",function(e){
    e.preventDefault();if(edit.busy)return;
    edit.busy=true;form.classList.add("busy");
    postHost({type:"textEdited",start:start,end:end,markdown:area.value});
  });
  area.addEventListener("keydown",function(e){
    if(e.key==="Escape"){e.preventDefault();review(null);}
    else if(e.key==="Enter"&&(e.metaKey||e.ctrlKey)){e.preventDefault();form.requestSubmit();}
  });
  form.querySelector(".discard").addEventListener("click",function(){review(null);});
  edit.slot.appendChild(form);
  area.focus();
  // The words that were selected, selected again inside the Markdown when they
  // appear in it as they read.
  if(edit.selection){var at=area.value.indexOf(edit.selection);if(at>=0)area.setSelectionRange(at,at+edit.selection.length);}
}
function review(state){
  removeSlot();clearMarks();hideBubble();edit.busy=false;edit.selection="";
  if(!state||!state.status)return;
  var els=blocksWithin(state.start,state.end);
  if(!els.length)return;
  var cls=state.status==="failed"?"edit-failed":state.status==="kept"?"edit-kept":state.status==="working"?"edit-busy":"edit-proposed";
  els.forEach(function(el){el.classList.add(cls);});
  var slot=slotAfter(els[els.length-1]);edit.slot=slot;
  var bar=document.createElement("div");bar.className="edit-bar "+state.status;bar.setAttribute("role","group");
  if(state.status==="kept"){
    bar.innerHTML='<span class="edit-bar-title">Change kept</span><button type="button" class="undo">Undo</button>';
    bar.querySelector(".undo").addEventListener("click",function(){postHost({type:"reviewUndo"});});
    setTimeout(function(){if(edit.slot===slot){removeSlot();clearMarks();}},8000);
  }else{
    bar.innerHTML='<div class="edit-bar-head"><span class="edit-bar-title"></span><span class="edit-bar-instruction"></span></div><p class="edit-note" hidden></p><form class="edit-bar-retry"><input type="text" autocomplete="off" aria-label="Adjust the instruction and try again"><button type="submit">Try again</button></form><div class="edit-bar-actions"><button type="button" class="keep">Keep</button><button type="button" class="discard">Discard</button></div>';
    bar.querySelector(".edit-bar-title").textContent=state.status==="failed"?"The AI could not make this change":state.status==="working"?"Rewriting\u2026":"Proposed change";
    bar.querySelector(".edit-bar-instruction").textContent=state.instruction?"\u201C"+state.instruction+"\u201D":"";
    if(state.message){var note=bar.querySelector(".edit-note");note.textContent=state.message;note.hidden=false;}
    var retry=bar.querySelector(".edit-bar-retry"),input=retry.querySelector("input");
    input.value=state.instruction||"";
    retry.addEventListener("submit",function(e){e.preventDefault();var text=input.value.trim();if(!text||edit.busy)return;edit.busy=true;bar.classList.add("busy");postHost({type:"reviewRetry",instruction:text});});
    var keep=bar.querySelector(".keep");
    keep.hidden=state.status!=="proposed";
    keep.addEventListener("click",function(){if(edit.busy)return;edit.busy=true;postHost({type:"reviewKeep"});});
    bar.querySelector(".discard").addEventListener("click",function(){if(edit.busy)return;postHost({type:"reviewDiscard"});});
    if(state.status==="working")bar.classList.add("busy");
  }
  slot.appendChild(bar);
  var first=els[0].getBoundingClientRect();
  if(first.top<0||first.bottom>window.innerHeight)els[0].scrollIntoView({block:"center"});
}
var pageAPI={
  enableEditing:function(){if(edit.on)return;edit.on=true;document.documentElement.classList.add("editing");},
  disableEditing:function(){edit.on=false;document.documentElement.classList.remove("editing");review(null);},
  review:review,
  source:source,
  clearReview:function(){review(null);}
};
window.ForeverLMPage=pageAPI;
var bubbleTimer=null;
document.addEventListener("selectionchange",function(){
  if(!edit.on)return;
  if(bubbleTimer)clearTimeout(bubbleTimer);
  bubbleTimer=setTimeout(function(){bubbleTimer=null;showBubble();},120);
});
document.addEventListener("mouseup",function(){if(edit.on)setTimeout(showBubble,0);});
window.addEventListener("scroll",function(){if(edit.bubble&&!edit.bubble.hidden&&edit.range)placeBubble(edit.range);},{passive:true});
window.addEventListener("message",function(e){
  var d=e.data;if(!d||d.source!=="foreverlm-host")return;
  if(d.type==="enableEditing")pageAPI.enableEditing();
  else if(d.type==="disableEditing")pageAPI.disableEditing();
  else if(d.type==="review")pageAPI.review(d.review||null);
  else if(d.type==="source")pageAPI.source(d.source||null);
});
})();
`.trim();function Zu(e){let r=new Date(e);return Number.isNaN(r.getTime())?"":r.toLocaleDateString("en-US",{year:"numeric",month:"long",day:"numeric",timeZone:"UTC"})}function i0(e,r){let t=new Set,n=new Map;for(let d of r.sets){for(let c of d.profiles){t.add(c.headingIndex);for(let h=c.headingIndex+1;h<e.length&&e[h].level>c.level;h+=1)t.add(h)}let p=-1;for(let c=d.profiles[0].headingIndex-1;c>=0;c-=1)if(e[c].level<d.profiles[0].level){p=c;break}n.set(p,r.sets.indexOf(d))}let i=e.map((d,p)=>({...d,position:p})).filter(d=>!t.has(d.position)&&d.level<=3);if(i.filter(d=>d.level<=2).length<3&&r.sets.length===0)return"";let s=d=>{let p=r.sets[d],c=p.profiles.map(h=>`<li><a href="#${h.id}"><span class="n">${S(h.label)}</span><span>${S(h.name)}</span></a></li>`).join("");return`<details class="profiles"><summary>${p.profiles.length} profiles</summary><ol class="profiles">${c}</ol></details>`},l=[];n.has(-1)&&l.push(`<li><a href="#${r.sets[n.get(-1)].id}">Directory</a>${s(n.get(-1))}</li>`);let u=0;for(;u<i.length;){let d=i[u];if(d.level>2){u+=1;continue}let p=[];for(u+=1;u<i.length&&i[u].level===3;)p.push(`<li><a href="#${i[u].id}">${S(i[u].text)}</a></li>`),u+=1;let c=p.length>0?`<ol>${p.join("")}</ol>`:"",h=n.has(d.position)?s(n.get(d.position)):"";l.push(`<li><a href="#${d.id}">${S(d.text)}</a>${c}${h}</li>`)}return`<nav class="contents" aria-label="Contents"><details class="fold" open><summary>Contents</summary><ol>${l.join("")}</ol></details></nav>`}function a0(e,r){if(r===0)return e;let t=e.profiles.map(i=>({...i,headingIndex:i.headingIndex-r})),n=new Map(e.profiles.map((i,a)=>[i,t[a]]));return{profiles:t,sources:e.sources,sets:e.sets.map(i=>({...i,profiles:i.profiles.map(a=>n.get(a))}))}}function s0(e){return e.replace(/&(?:lt|gt|quot|#39|amp);/g,r=>({"&lt;":"<","&gt;":">","&quot;":'"',"&#39;":"'","&amp;":"&"})[r])}function Xu(e,r,t=`${r}s`){return`${e} ${e===1?r:t}`}function o0(e){let r=e.title.trim()||"Untitled",t=Yu(e.markdown,r),n=Vu(t.markdown,{...e.sourceMarks?{sourceOffset:t.offset}:{},...e.docLinks?{docLinks:e.docLinks}:{}}),i=S(r),a="",s="",l=n.html,u=n.headings,d=/^<h1 id="([^"]+)"((?: data-src="[^"]*")?)>([\s\S]*?)<\/h1>\n?/.exec(l);d&&n.headings[0]?.level===1&&n.headings[0].id===d[1]&&!n.index.profiles.some($=>$.headingIndex===0)&&(i=d[3],a=d[2],s=S(r),l=l.slice(d[0].length),u=n.headings.slice(1));let p=Zu(e.publishedAt),c=Zu(e.updatedAt),h=c&&c!==p?`Published ${S(p)} \xB7 Updated ${S(c)}`:`Published ${S(p)}`,x=$=>$.replace(/<sup class="fn-ref">[\s\S]*?<\/sup>/g,"").replace(/<section class="footnotes"[\s\S]*$/,""),v=($=>s0(x($).replace(/<[^>]+>/g," ")))(n.deck||n.html).replace(/\s+/g," ").trim().slice(0,200),m=`${e.canonicalURL}.md`,g=Math.max(1,Math.round(n.words/230)),b=n.index.profiles.length,y=n.index.sources.length,q=n.index.sources.some($=>$.libraryType!==null),E=[h,`${g} min read`];b>0&&E.push(Xu(b,"profile")),y>0&&E.push(Xu(y,"source")),E.push(`<a href="${S(m)}">Markdown</a>`);let W=i0(u,a0(n.index,u===n.headings?0:1));return`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>${S(r)}</title>
<meta name="description" content="${S(v)}">
<meta name="robots" content="noindex">
<meta property="og:type" content="article">
<meta property="og:title" content="${S(r)}">
<meta property="og:description" content="${S(v)}">
<meta property="og:url" content="${S(e.canonicalURL)}">
<meta property="og:site_name" content="ForeverLM">
<link rel="canonical" href="${S(e.canonicalURL)}">
<link rel="alternate" type="text/markdown" href="${S(m)}">
<link rel="icon" href="https://foreverlm.com/favicon.ico">
<style>${n0}</style>
</head>
<body>
<div class="page">
<a class="brand" href="https://foreverlm.com/"><img src="https://foreverlm.com/assets/app-icon.png" alt="" width="22" height="22">ForeverLM</a>
<header class="doc">
${s?`<p class="kicker">${s}</p>
`:""}<h1${a}>${i}</h1>
${n.deck?`<p class="deck">${n.deck}</p>
`:""}<p class="meta">${E.join('<span class="dot">\xB7</span>')}</p>
</header>
<div class="layout">
${W}
<article>
${l}
</article>
</div>
<footer class="doc">
<span>Written in <a class="mark" href="https://foreverlm.com/">ForeverLM</a>, published by its author.${q?" Add to library files a source into your own ForeverLM library.":""}</span>
<a href="https://foreverlm.com/">What is ForeverLM?</a>
</footer>
</div>
<script>${Ju}</script>
</body>
</html>
`}return sc(l0);})();
