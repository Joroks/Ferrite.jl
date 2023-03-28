"""
    create_sparsity_pattern(dh::DofHandler; coupling)

Create the sparsity pattern corresponding to the degree of freedom
numbering in the [`DofHandler`](@ref). Return a `SparseMatrixCSC`
with stored values in the correct places.

The keyword argument `coupling` can be used to specify how fields (or components) in the dof
handler couple to each other. `coupling` should be a square matrix of booleans with
`nfields` (or `ncomponents`) rows/columns with `true` if fields are coupled and `false` if
not. By default full coupling is assumed.

See the [Sparsity Pattern](@ref) section of the manual.
"""
function create_sparsity_pattern(dh::AbstractDofHandler; coupling=nothing)
    return _create_sparsity_pattern(dh, nothing, false, true, coupling)
end

"""
    create_symmetric_sparsity_pattern(dh::DofHandler; coupling)

Create the symmetric sparsity pattern corresponding to the degree of freedom
numbering in the [`DofHandler`](@ref) by only considering the upper
triangle of the matrix. Return a `Symmetric{SparseMatrixCSC}`.

See the [Sparsity Pattern](@ref) section of the manual.
"""
function create_symmetric_sparsity_pattern(dh::AbstractDofHandler; coupling=nothing)
    return Symmetric(_create_sparsity_pattern(dh, nothing, true, true, coupling), :U)
end

"""
    create_symmetric_sparsity_pattern(dh::AbstractDofHandler, ch::ConstraintHandler, coupling)

Create a symmetric sparsity pattern accounting for affine constraints in `ch`. See
the Affine Constraints section of the manual for further details.
"""
function create_symmetric_sparsity_pattern(dh::AbstractDofHandler, ch::ConstraintHandler;
        keep_constrained::Bool=true, coupling=nothing)
    return Symmetric(_create_sparsity_pattern(dh, ch, true, keep_constrained, coupling), :U)
end

"""
    create_sparsity_pattern(dh::AbstractDofHandler, ch::ConstraintHandler; coupling)

Create a sparsity pattern accounting for affine constraints in `ch`. See
the Affine Constraints section of the manual for further details.
"""
function create_sparsity_pattern(dh::AbstractDofHandler, ch::ConstraintHandler;
        keep_constrained::Bool=true, coupling=nothing)
    return _create_sparsity_pattern(dh, ch, false, keep_constrained, coupling)
end

# Compute a coupling matrix of size (ndofs_per_cell × ndofs_per_cell) based on the input
# coupling which can be of size i) (nfields × nfields) specifying coupling between fields,
# ii) (ncomponents × ncomponents) specifying coupling between components, or iii)
# (ndofs_per_cell × ndofs_per_cell) specifying coupling between all local dofs, i.e. a
# "template" local matrix.
function _coupling_to_local_dof_coupling(dh::DofHandler, coupling::AbstractMatrix{Bool}, sym::Bool)
    out = zeros(Bool, ndofs_per_cell(dh), ndofs_per_cell(dh))
    sz = size(coupling, 1)
    sz == size(coupling, 2) || error("coupling not square")
    sym && (issymmetric(coupling) || error("coupling not symmetric"))
    dof_ranges = [dof_range(dh, f) for f in dh.field_names]
    if sz == length(dh.field_names) # Coupling given by fields
        for (j, jrange) in pairs(dof_ranges), (i, irange) in pairs(dof_ranges)
            out[irange, jrange] .= coupling[i, j]
        end
    elseif sz == sum(dh.field_dims) # Coupling given by components
        component_offsets = pushfirst!(cumsum(dh.field_dims), 0)
        for (jf, jrange) in pairs(dof_ranges), (j, J) in pairs(jrange)
            jc = mod1(j, dh.field_dims[jf]) + component_offsets[jf]
            for (i_f, irange) in pairs(dof_ranges), (i, I) in pairs(irange)
                ic = mod1(i, dh.field_dims[i_f]) + component_offsets[i_f]
                out[I, J] = coupling[ic, jc]
            end
        end
    elseif sz == ndofs_per_cell(dh) # Coupling given by template local matrix
        out .= coupling
    else
        error("could not create coupling")
    end
    return out
end

function _create_sparsity_pattern(dh::AbstractDofHandler, ch#=::Union{ConstraintHandler, Nothing}=#, sym::Bool, keep_constrained::Bool, coupling::Union{AbstractMatrix{Bool},Nothing})
    @assert isclosed(dh)
    if !keep_constrained
        @assert ch !== nothing && isclosed(ch)
    end
    ncells = getncells(dh.grid)
    if coupling !== nothing
        # Extend coupling to be of size (ndofs_per_cell × ndofs_per_cell)
        coupling = _coupling_to_local_dof_coupling(dh, coupling, sym)
    end
    # Compute approximate size for the buffers using the dofs in the first element
    n = ndofs_per_cell(dh)
    N = (coupling === nothing ? (sym ? div(n*(n+1), 2) : n^2) : count(coupling)) * ncells
    N += ndofs(dh) # always add the diagonal elements
    I = Int[]; resize!(I, N)
    J = Int[]; resize!(J, N)
    global_dofs = zeros(Int, n)
    cnt = 0
    for element_id in 1:ncells
        # MixedDofHandler might have varying number of dofs per element
        resize!(global_dofs, ndofs_per_cell(dh, element_id))
        celldofs!(global_dofs, dh, element_id)
        @inbounds for j in eachindex(global_dofs), i in eachindex(global_dofs)
            coupling === nothing || coupling[i, j] || continue
            dofi = global_dofs[i]
            dofj = global_dofs[j]
            sym && (dofi > dofj && continue)
            !keep_constrained && (haskey(ch.dofmapping, dofi) || haskey(ch.dofmapping, dofj)) && continue
            cnt += 1
            if cnt > length(J)
                resize!(I, trunc(Int, length(I) * 1.5))
                resize!(J, trunc(Int, length(J) * 1.5))
            end
            I[cnt] = dofi
            J[cnt] = dofj

        end
    end
    @inbounds for d in 1:ndofs(dh)
        cnt += 1
        if cnt > length(J)
            resize!(I, trunc(Int, length(I) + ndofs(dh)))
            resize!(J, trunc(Int, length(J) + ndofs(dh)))
        end
        I[cnt] = d
        J[cnt] = d
    end

    resize!(I, cnt)
    resize!(J, cnt)

    K = spzeros!!(Float64, I, J, ndofs(dh), ndofs(dh))

    # If ConstraintHandler is given, create the condensation pattern due to affine constraints
    if ch !== nothing
        @assert isclosed(ch)
        fill!(K.nzval, 1)
        _condense_sparsity_pattern!(K, ch.dofcoefficients, ch.dofmapping, keep_constrained)
        fillzero!(K)
    end

    return K
end

# Similar to Ferrite._condense!(K, ch), but only add the non-zero entries to K (that arises from the condensation process)
function _condense_sparsity_pattern!(K::SparseMatrixCSC{T}, dofcoefficients::Vector{Union{Nothing,DofCoefficients{T}}}, dofmapping::Dict{Int,Int}, keep_constrained::Bool) where T
    ndofs = size(K, 1)

    # Return early if there are no non-trivial affine constraints
    any(i -> !(i === nothing || isempty(i)), dofcoefficients) || return

    # Adding new entries to K is extremely slow, so create a new sparsity triplet for the
    # condensed sparsity pattern
    N = 2 * length(dofcoefficients) # TODO: Better size estimate for additional condensed sparsity pattern.
    I = Int[]; resize!(I, N)
    J = Int[]; resize!(J, N)

    cnt = 0
    for col in 1:ndofs
        col_coeffs = coefficients_for_dof(dofmapping, dofcoefficients, col)
        if col_coeffs === nothing
            !keep_constrained && haskey(dofmapping, col) && continue
            for ri in nzrange(K, col)
                row = K.rowval[ri]
                row_coeffs = coefficients_for_dof(dofmapping, dofcoefficients, row)
                row_coeffs === nothing && continue
                for (d, _) in row_coeffs
                    cnt += 1
                    _add_or_grow(cnt, I, J, d, col)
                end
            end
        else
            for ri in nzrange(K, col)
                row = K.rowval[ri]
                row_coeffs = coefficients_for_dof(dofmapping, dofcoefficients, row)
                if row_coeffs === nothing
                    !keep_constrained && haskey(dofmapping, row) && continue
                    for (d, _) in col_coeffs
                        cnt += 1
                        _add_or_grow(cnt, I, J, row, d)
                    end
                else
                    for (d1, _) in col_coeffs
                        !keep_constrained && haskey(dofmapping, d1) && continue
                        for (d2, _) in row_coeffs
                            !keep_constrained && haskey(dofmapping, d2) && continue
                            cnt += 1
                            _add_or_grow(cnt, I, J, d1, d2)
                        end
                    end
                end
            end
        end
    end

    resize!(I, cnt)
    resize!(J, cnt)

    # Fill the sparse matrix with a non-zero value so that :+ operation does not remove entries with value zero.
    K2 = spzeros!!(Float64, I, J, ndofs, ndofs)
    fill!(K2.nzval, 1)

    K .+= K2

    return nothing
end