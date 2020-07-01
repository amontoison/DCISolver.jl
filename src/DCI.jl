module DCI

using LinearAlgebra, Logging

using Krylov, LinearOperators, NLPModels, SolverTools, SparseArrays

export dci

include("dci_normal.jl")
include("dci_tangent.jl")

"""
    dci(nlp; kwargs...)

This method implements the Dynamic Control of Infeasibility for equality-constrained
problems described in

    Dynamic Control of Infeasibility in Equality Constrained Optimization
    Roberto H. Bielschowsky and Francisco A. M. Gomes
    SIAM J. Optim., 19(3), 1299–1325.
    https://doi.org/10.1137/070679557

"""
function dci(nlp :: AbstractNLPModel;
             atol = 1e-8,
             rtol = 1e-6,
             ctol = 1e-6,
             max_eval = 1000,
             max_time = 60
            )
  if !equality_constrained(nlp)
    error("DCI only works for equality constrained problems")
  end

  f(x) = obj(nlp, x)
  ∇f(x) = grad(nlp, x)
  c(x) = cons(nlp, x)
  J(x) = jac_op(nlp, x)

  x = nlp.meta.x0
  z = copy(x)
  fz = fx = f(x)
  ∇fx = ∇f(x)
  cx = c(x)
  Jx = J(x)
  # λ = argmin ‖∇f + Jᵀλ‖
  λ = cgls(Jx', -∇fx)[1]

  # Allocate the sparse structure of K = [H + γI  [Jᵀ]; J -δI]
  nnz = nlp.meta.nnzh + nlp.meta.nnzj + nlp.meta.nvar + nlp.meta.ncon # H, J, γI, -δI
  rows = zeros(Int, nnz)
  cols = zeros(Int, nnz)
  vals = zeros(nnz)
  nnz_idx = 1:nlp.meta.nnzh
  @views hess_structure!(nlp, rows[nnz_idx], cols[nnz_idx])
  nnz_idx = nlp.meta.nnzh .+ (1:nlp.meta.nnzj)
  @views jac_structure!(nlp, rows[nnz_idx], cols[nnz_idx])
  @views jac_coord!(nlp, x, vals[nnz_idx])
  nnz_idx = nlp.meta.nnzh .+ nlp.meta.nnzj .+ (1:nlp.meta.nvar)
  rows[nnz_idx] .= 1:nlp.meta.nvar
  cols[nnz_idx] .= 1:nlp.meta.nvar
  vals[nnz_idx] .= 1e-8
  nnz_idx = nlp.meta.nnzh .+ nlp.meta.nnzj .+ nlp.meta.nvar .+ (1:nlp.meta.ncon)
  rows[nnz_idx] .= nlp.meta.nvar .+ (1:nlp.meta.ncon)
  cols[nnz_idx] .= nlp.meta.nvar .+ (1:nlp.meta.ncon)
  vals[nnz_idx] .= -1e-8

  #ℓ(x,λ) = f(x) + λᵀc(x)
  ℓxλ = fx + dot(λ, cx)
  ∇ℓxλ = ∇fx + Jx'*λ

  ρmax = 1.0
  ρ = 1.0

  dualnorm = norm(∇ℓxλ)
  primalnorm = norm(cx)

  start_time = time()
  eltime = 0.0

  ϵd = atol + rtol * dualnorm
  ϵp = atol + rtol * primalnorm

  solved = primalnorm < ϵp && dualnorm < ϵd
  tired = neval_obj(nlp) + neval_cons(nlp) > max_eval || eltime > max_time
  infeasible = false

  iter = 0

  @info log_header([:stage, :iter, :nf, :fx, :dual, :primal, :ρ, :status],
                   [String, Int, Int, Float64, Float64, Float64, Float64, String],
                   hdr_override=Dict(:nf => "#f", :fx => "f(x)", :dual => "‖∇L‖", :primal => "‖c(x)‖")
                  )
  @info log_row(Any["init", iter, neval_obj(nlp), fx, dualnorm, primalnorm, ρ])

  while !(solved || tired || infeasible)
    # Normal step
    done_with_normal_step = false
    local ℓzλ
    while !done_with_normal_step
      ngp = dualnorm/(norm(∇fx) + 1)
      z, cz, ρ, normal_status = normal_step(nlp, ϵp, x, cx, Jx, ρ, ρmax, ngp, max_eval=max_eval, max_time=max_time-eltime)
      λ = cgls(Jx', -∇fx)[1]
      fz = f(z)
      ℓzλ = fz + dot(λ, cz)
      ∇ℓxλ = ∇fx + Jx'*λ
      primalnorm = norm(cz)
      ∇fx = ∇f(x)
      ∇ℓxλ = ∇fx + Jx'*λ
      dualnorm = norm(∇ℓxλ)
      @info log_row(Any["N", iter, neval_obj(nlp), fz, dualnorm, primalnorm, ρ, normal_status])
      tired = neval_obj(nlp) + neval_cons(nlp) > max_eval || eltime > max_time
      infeasible = normal_status == :infeasible
      done_with_normal_step = primalnorm ≤ ρ || tired || infeasible 
    end

    # Convergence test
    solved = primalnorm < ϵp && dualnorm < ϵd

    if solved || tired || infeasible
      break
    end

    @views hess_coord!(nlp, x, λ, vals[1:nlp.meta.nnzh])
    # TODO: Don't compute every time
    @views jac_coord!(nlp, x, vals[nlp.meta.nnzh .+ (1:nlp.meta.nnzj)])
    # TODO: Update γ and δ here
    x, tg_status = tangent_step(nlp, z, λ, rows, cols, vals, ∇ℓxλ, Jx, ℓzλ, ρ, max_eval=max_eval, max_time=max_time-eltime)
    #=
    if tg_status != :success
      tired = true
      continue
    end
    =#
    fx = obj(nlp, x)
    cx = c(x)
    ∇fx = ∇f(x)
    Jx = J(x)
    # λ = cgls(Jx', -∇fx)[1]
    ℓxλ = fx + dot(λ, cx)
    ∇ℓxλ = ∇fx + Jx'*λ
    primalnorm = norm(cx)
    dualnorm = norm(∇ℓxλ)
    @info log_row(Any["T", iter, neval_obj(nlp), fx, dualnorm, primalnorm, ρ])
    iter += 1
    solved = primalnorm < ϵp && dualnorm < ϵd
    tired = neval_obj(nlp) + neval_cons(nlp) > max_eval || eltime > max_time
  end

  status = if solved
    :first_order
  elseif tired
    if neval_obj(nlp) + neval_cons(nlp) > max_eval
      :max_eval
    elseif eltime > max_time
      :max_time
    else
      :exception
    end
  elseif infeasible
    :infeasible
  else
    :unknown
  end

  return GenericExecutionStats(status, nlp, solution=z, objective=fz, dual_feas=dualnorm, primal_feas=primalnorm, elapsed_time=eltime)
end

end # module