"""
function logmean(aL,aR,logL,logR)

"""

function logmean(aL,aR,logL,logR)

    "from: Entropy stable num. approx. for the isothermal and polytropic Euler"
    # assumes the specific value γ = 1.4
    da = aR-aL;
    aavg = .5*(aR+aL);
    f = da/aavg;
    v = f^2;
    if abs(f)<1e-4
        return aavg*(1 + v*(-.2-v*(.0512 - v*0.026038857142857)))
    else
        return -da/(logL-logR)
    end
end

"""
function logmean(aL,aR)
"""

function logmean(aL,aR)
    return logmean(aL,aR,log(aL),log(aR))
end
