# "Packages"
using Revise # reduce need for recompile
using Plots
using Documenter
using LinearAlgebra
using SparseArrays

# "User defined modules"
push!(LOAD_PATH, "./src")
using CommonUtils
using Basis1D
using Basis2DQuad # face trace space
using Basis3DHex
using UniformHexMesh

push!(LOAD_PATH, "./examples/EntropyStableEuler")
using EntropyStableEuler

N = 2
K1D = 1
T = 2/3 # endtime
CFL = 1.0

VX,VY,VZ,EToV = uniform_hex_mesh(K1D,K1D,K1D)
FToF = connect_mesh(EToV,hex_face_vertices())
Nfaces, K = size(FToF)


r,s,t = nodes_3D(N)
V = vandermonde_3D(N,r,s,t)
Dr,Ds,Dt = (A->A/V).(grad_vandermonde_3D(N,r,s,t))

"quadrature"
# rq,sq,tq,wq = quad_nodes_3D(N)
r1D,w1D = gauss_lobatto_quad(0,0,N)
r1D,w1D = gauss_quad(0,0,N)
rq,sq,tq = meshgrid(r1D,r1D,r1D)
wr,ws,wt = meshgrid(w1D,w1D,w1D)
wq = wr.*ws.*wt

Vq = vandermonde_3D(N,rq,sq,tq)/V
M = transpose(Vq)*diagm(wq)*Vq
Pq = M\(transpose(Vq)*diagm(wq))

"face nodes and matrices"
# rquad,squad,wquad = Basis2DQuad.quad_nodes_2D(N)
rquad,squad = (x->x[:]).(meshgrid(r1D,r1D))
wr,ws = (x->x[:]).(meshgrid(w1D,w1D))
wquad = wr.*ws

e = ones(size(rquad))
zz = zeros(size(rquad))
rf = [-e; e; rquad; rquad; rquad; rquad]
sf = [rquad; rquad; -e; e; squad; squad]
tf = [squad; squad; squad; squad; -e; e]
wf = vec(repeat(wquad,Nfaces,1));
nrJ = [-e; e; zz;zz; zz;zz]
nsJ = [zz;zz; -e; e; zz;zz]
ntJ = [zz;zz; zz;zz; -e; e]

"surface operators"
Vf = vandermonde_3D(N,rf,sf,tf)/V
Lf = M\(transpose(Vf)*diagm(wf))

"Make hybridized SBP operators"
Qr = Pq'*M*Dr*Pq
Qs = Pq'*M*Ds*Pq
Qt = Pq'*M*Dt*Pq
Ef = Vf*Pq
Br = diagm(wf.*nrJ)
Bs = diagm(wf.*nsJ)
Bt = diagm(wf.*ntJ)
Qrh = .5*[Qr-Qr' Ef'*Br;
-Br*Ef Br]
Qsh = .5*[Qs-Qs' Ef'*Bs;
-Bs*Ef Bs]
Qth = .5*[Qt-Qt' Ef'*Bt;
-Bt*Ef Bt]

"operators to and from hybridized quad points"
Vh = [Vq; Vf]
Ph = 2*(M\transpose(Vh))

"sparse skew symmetric versions of the operators"
Qrhskew = .5*(Qrh-transpose(Qrh))
Qshskew = .5*(Qsh-transpose(Qsh))
Qthskew = .5*(Qth-transpose(Qth))
Qrhskew_sparse = droptol!(sparse(Qrhskew),1e-12)
Qshskew_sparse = droptol!(sparse(Qshskew),1e-12)
Qthskew_sparse = droptol!(sparse(Qthskew),1e-12)

# precompute union of sparse ids for Qr, Qs
Qnzids = [unique([Qrhskew_sparse[i,:].nzind; Qshskew_sparse[i,:].nzind; Qthskew_sparse[i,:].nzind]) for i = 1:size(Qrhskew,1)]

"map nodes"
r1,s1,t1 = nodes_3D(1)
V1 = vandermonde_3D(1,r,s,t)/vandermonde_3D(1,r1,s1,t1)
x = V1*VX[transpose(EToV)]
y = V1*VY[transpose(EToV)]
z = V1*VZ[transpose(EToV)]

"get physical face nodes"
xf,yf,zf = (x->Vf*x).((x,y,z))
mapM, mapP, mapB = build_node_maps((xf,yf,zf),FToF)
mapM = reshape(mapM,length(rf),K)
mapP = reshape(mapP,length(rf),K)

"make periodic"
LX = 2; LY = 2; LZ = 2
mapPB = build_periodic_boundary_maps(xf,yf,zf,LX,LY,LZ,Nfaces*K,mapM,mapP,mapB)
mapP[mapB] = mapPB

"add curved mapping"
a = .05
dx = @. (x-1)*(x+1)*(y-1)*(y+1)*(z-1)*(z+1)
x = x + a.*dx
y = y + a.*dx
z = z + a.*dx

"Geometry"
vgeo = geometric_factors(x,y,z,Dr,Ds,Dt)
(rxJ, sxJ, txJ, ryJ, syJ, tyJ, rzJ, szJ, tzJ, J) = vgeo
nxJ = nrJ.*(Vf*rxJ) + nsJ.*(Vf*sxJ) + ntJ.*(Vf*txJ)
nyJ = nrJ.*(Vf*ryJ) + nsJ.*(Vf*syJ) + ntJ.*(Vf*tyJ)
nzJ = nrJ.*(Vf*rzJ) + nsJ.*(Vf*szJ) + ntJ.*(Vf*tzJ)
sJ = @. sqrt(nxJ.^2 + nyJ.^2 + nzJ.^2)

"initial conditions"
rhoex(x,y,z,t) = @. 2 + .5*sin(pi*(x-t))
rho = rhoex(x,y,z,0)
u = ones(size(x))
v = zeros(size(x))
w = zeros(size(x))
p = ones(size(x))
Q = primitive_to_conservative(rho,u,v,w,p)

"Pack arguments into tuples"
vgeo = (x->Vh*x).(vgeo)
fgeo = (nxJ,nyJ,nzJ,sJ)
Nfp = convert(Int,length(rf)/Nfaces)
mapP = reshape(mapP,Nfp*Nfaces,K)
nodemaps = (mapP,mapB)

"convert to Gauss node basis"
J = Vq*J
wJq = diagm(wq)*J
Q = (x->Vq*x).(Q)
Vh = droptol!(sparse(vcat(diagm(ones(length(rq))), Ef)),1e-12)
Ph = droptol!(sparse(2*diagm(@. 1/wq)*transpose(Vh)),1e-12)
Lf = droptol!(sparse(diagm(@. 1/wq)*(transpose(Ef)*diagm(wf))),1e-12)
ops = (Qrhskew_sparse,Qshskew_sparse,Qthskew_sparse,Qnzids,Ph,Lf)

"timestepping"
rk4a,rk4b,rk4c = rk45_coeffs()
CN = (N+1)*(N+2)*3/2  # estimated trace constant
dt = CFL * 2 / (CN*K1D)
Nsteps = convert(Int,ceil(T/dt))

"sparse version - precompute sparse row ids for speed"
function sparse_hadamard_sum(Qhe,ops,vgeo,flux_fun)

    (Qr,Qs,Qt,Qnzids) = ops
    # (rxJ,sxJ,txJ,ryJ,syJ,tyJ,rzJ,szJ,tzJ,_) = vgeo
    nrows = size(Qr,1)
    nfields = length(Qhe)

    # precompute logs for logmean
    (rho,u,v,w,beta) = Qhe
    Qlog = (log.(rho), log.(beta))

    rhsQe = ntuple(x->zeros(nrows),nfields)
    rhsi = zeros(nfields) # prealloc a small array
    for i = 1:nrows
        Qi = (x->x[i]).(Qhe)
        Qlogi = (x->x[i]).(Qlog)
        vgeo_i = (x->x[i]).(vgeo)

        fill!(rhsi,0) # reset rhsi before accumulation
        for j = Qnzids[i] # nonzero row entries
            Qj = (x->x[j]).(Qhe)
            Qlogj = (x->x[j]).(Qlog)
            vgeo_j = (x->x[j]).(vgeo)

            avg(uL,uR) = .5*(uL+uR)
            rxJa,sxJa,txJa,ryJa,syJa,tyJa,rzJa,szJa,tzJa,_ = avg.(vgeo_i,vgeo_j)

            Fx,Fy,Fz = flux_fun(Qi,Qj,Qlogi,Qlogj)
            Fr = @. rxJa*Fx + ryJa*Fy + rzJa*Fz
            Fs = @. sxJa*Fx + syJa*Fy + szJa*Fz
            Ft = @. txJa*Fx + tyJa*Fy + tzJa*Fz

            # sum(Qx.*Fx + Qy.*Fy,2) = sum(Qr*rxJ*Fx + Qs*sxJ*Fx + Qr*ryJ*Fy ...)
            @. rhsi += Qr[i,j]*Fr + Qs[i,j]*Fs + Qt[i,j]*Ft
        end

        # faster than one-line fixes (no return args)
        for fld in eachindex(rhsQe)
            rhsQe[fld][i] = rhsi[fld]
        end
    end

    return rhsQe
end

"Qh = (rho,u,v,beta), while Uh = conservative vars"
function rhs(Qh,UM,ops,vgeo,fgeo,nodemaps,flux_fun)

    # unpack args
    (Qrh_sparse,Qsh_sparse,Qth_sparse,Qnzids,Ph,Lf)=ops
    (nxJ,nyJ,nzJ,sJ) = fgeo
    (mapP,mapB) = nodemaps
    Nh = size(Qrh_sparse,1)
    Nq = size(Ph,1)
    K  = size(Qh[1],2)

    QM = (x->x[Nq+1:end,:]).(Qh)
    QP = (x->x[mapP]).(QM)

    # lax friedrichs dissipation
    (rho,rhou,rhov,rhow,E) = UM
    rhoU_n = @. (rhou*nxJ + rhov*nyJ + rhow*nzJ)/sJ
    lam = abs.(wavespeed(rho,rhoU_n,E))
    LFc = 0*.5*max.(lam,lam[mapP]).*sJ

    fSx,fSy,fSz = flux_fun(QM,QP)
    normal_flux(fx,fy,fz,uM) = fx.*nxJ + fy.*nyJ + fz.*nzJ - LFc.*(uM[mapP]-uM)
    flux = normal_flux.(fSx,fSy,fSz,UM)
    rhsQ = (x->Lf*x).(flux)

    # compute volume contributions using flux differencing
    for e = 1:K
        Qhe = tuple((x->x[:,e]).(Qh)...)
        #vgeo_elem = (x->x[1,e]).(vgeo) # assumes affine elements for now
        vgeo_elem = (x->x[:,e]).(vgeo) # assumes curved elements

        Qops = (Qrh_sparse,Qsh_sparse,Qth_sparse,Qnzids)
        QFe = sparse_hadamard_sum(Qhe,Qops,vgeo_elem,flux_fun) # sum(Q.*F,dims=2)

        applyPh!(X,x,e) = X[:,e] += Ph*x
        applyPh!.(rhsQ,QFe,e)
    end

    return (x -> -x./J).(rhsQ) # scale by Jacobian
end

function rk_step!(Q,resQ,rka,rkb,compute_rhstest)

    VU = v_ufun(Q...)
    Uf = u_vfun((x->Ef*x).(VU)...) # conservative vars
    Uh = vcat.(Q,Uf)

    # convert to rho,u,v,beta vars
    (rho,rhou,rhov,rhow,E) = Uh
    beta = betafun(rho,rhou,rhov,rhow,E)
    Qh = (rho,rhou./rho,rhov./rho,rhow./rho,beta) # redefine Q = (rho,U,β)

    rhsQ = rhs(Qh,Uf,ops,vgeo,fgeo,nodemaps,euler_fluxes)
    # rhsQ = [zeros(size(ops[5],1),size(Q[1],2)) for i = 1:5]

    rhstest = 0
    if compute_rhstest
        for fld in eachindex(rhsQ)
            rhstest += sum(wJq.*VU[fld].*rhsQ[fld])
        end
    end

    @. resQ = rka*resQ + dt*rhsQ
    @. Q += rkb*resQ

    return rhstest
end


# force Q to be an array of arrays for mutability
Q = collect(Q)
resQ = [zeros(size(x)) for i in eachindex(Q)]

for i = 1:Nsteps

    rhstest = 0
    for INTRK = 1:5
        rhstest = rk_step!(Q,resQ,rk4a[INTRK],rk4b[INTRK],INTRK==5)
    end

    if i%10==0 || i==Nsteps
        println("Time step: $i out of $Nsteps with rhstest = $rhstest")
    end
end

(rho,rhou,rhov,rhow,E) = (x->Pq*x).(Q) # project back to Lobatto nodes

rq2,sq2,tq2,wq2 = quad_nodes_3D(N+2)
Vq2 = vandermonde_3D(N,rq2,sq2,tq2)/V
(xq2,yq2,zq2) = (x->Vq2*x).((x,y,z))
wJq2 = abs.(diagm(wq2)*(Vq2*J))

L2err = sum(wJq2.*(Vq2*rho - rhoex(xq2,yq2,zq2,T)).^2)

@show L2err

"plotting nodes"
rp, sp, tp = equi_nodes_3D(25)
Vp = vandermonde_3D(N,rp,sp,tp)/V

# pyplot(size=(100,100),legend=false,markerstrokewidth=0,markersize=2)
gr(size=(200,200),legend=false,markerstrokewidth=0,markersize=2)

(xp,yp,zp,vv) = (x->Vp*x).((x,y,z,rho))

ids = map(x->x[1],findall(@. abs(zp[:])<1e-10))
(xp,yp,zp,vv) = (x->x[ids]).((xp,yp,zp,vv))
scatter(xp,yp,vv,zcolor=vv,camera=(0,90))
