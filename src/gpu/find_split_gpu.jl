"""
    build a single histogram containing all grads and weight information
"""
# GPU - apply along the features axis
# function hist_kernel!(h::CuDeviceArray{T,4}, δ::CuDeviceMatrix{T}, idx::CuDeviceMatrix{UInt8}, 
#     𝑖::CuDeviceVector{S}, 𝑗::CuDeviceVector{S}, 𝑛::CuDeviceVector{S}, L) where {T,S}

#     it = threadIdx().x
#     id = blockDim().x
#     ib = blockIdx().x
#     ig = gridDim().x

#     # k = blockIdx().z
#     # i = threadIdx().x + (blockIdx().x - 1) * blockDim().x

#     j = threadIdx().y + (blockIdx().y - 1) * blockDim().y

#     i_tot = length(𝑖)
#     iter = 0
#     while iter * id * ig < i_tot
#         i = it + id * (ib - 1) + iter * id * ig
#         if i <= length(𝑖) && j <= length(𝑗)
#             n = 𝑛[i]
#             if n > 0
#                 pt = Base._to_linear_index(h, 1, idx[𝑖[i], 𝑗[j]], 𝑗[j], n)
#                 for k in 1:L
                    # CUDA.atomic_add!(pointer(h, pt + k - 1), δ[𝑖[i], k])
#                 end
#             end
#         end
#         iter += 1
#     end
#     return nothing
# end


function hist_kernel!(h::CuDeviceArray{T,4}, δ::CuDeviceMatrix{T}, xid::CuDeviceMatrix{UInt8}, 
    𝑖::CuDeviceVector{S}, 𝑗::CuDeviceVector{S}, 𝑛::CuDeviceVector{S}) where {T,S}
    
    nbins = size(h, 2)

    it = threadIdx().x
    id, jd = blockDim().x, blockDim().y
    ib, j, k = blockIdx().x, blockIdx().y, blockIdx().z
    ig, jg = gridDim().x, gridDim().y
    
    shared = @cuDynamicSharedMem(T, (size(h, 2), size(h, 4)))
    fill!(shared, 0)
    sync_threads()

    i_tot = length(𝑖)
    iter = 0
    while iter * id * ig < i_tot
        i = it + id * (ib - 1) + iter * id * ig
        if i <= length(𝑖) && j <= length(𝑗)
            # depends on shared to be assigned to a single feature
            @inbounds n = 𝑛[i]
            @inbounds i_idx = 𝑖[i]
            @inbounds CUDA.atomic_add!(pointer(shared, xid[i_idx, 𝑗[j]] + nbins * (n-1)), δ[i_idx, k])
            # @inbounds shared[xid[i_idx, 𝑗[j]] + nbins * (n-1)] += δ[i_idx, k]
        end
        iter += 1
    end
    sync_threads()
    # loop to cover cases where nbins > nthreads
    for iter in 1:(nbins - 1) ÷ id + 1
        bin_id = it + id * (iter - 1)
        n = 1 # need to loop over nodes
        if bin_id <= nbins
            @inbounds δid = Base._to_linear_index(h, k, bin_id, 𝑗[j], 1)
            @inbounds CUDA.atomic_add!(pointer(h, δid), shared[bin_id, 1])
        end
    end
    return nothing
end

# base approach - block built along the cols first, the rows (limit collisions)
function update_hist_gpu!(
    h::CuArray{T,4}, 
    δ::CuMatrix{T}, 
    X_bin::CuMatrix{UInt8}, 
    𝑖::CuVector{S}, 
    𝑗::CuVector{S}, 
    𝑛::CuVector{S}, 
    K; MAX_THREADS=128) where {T,S}
    
    fill!(h, 0.0)
    thread_i = min(MAX_THREADS, length(𝑖))
    threads = (thread_i,)
    blocks = (1, length(𝑗), 2 * K + 1)
    # blocks = (ceil(Int, length(𝑖) / thread_i), length(𝑗))
    @cuda blocks = blocks threads = threads shmem = sizeof(T) * size(h, 2) * size(h, 4) hist_kernel!(h, δ, X_bin, 𝑖, 𝑗, 𝑛)
    return
end

# update the vector of length 𝑖 pointing to associated node id
function update_set_kernel!(mask, set, best, x_bin)
    it = threadIdx().x
    ibd = blockDim().x
    ibi = blockIdx().x
    i = it + ibd * (ibi - 1)
    @inbounds if i <= length(set)
        @inbounds mask[i] = x_bin[set[i]] <= best
    end
    return nothing
end

function update_set_gpu(set, best, x_bin; MAX_THREADS=1024)
    mask = CUDA.zeros(Bool, length(set))
    thread_i = min(MAX_THREADS, length(set))
    threads = (thread_i,)
    blocks = (length(set) ÷ thread_i + 1,)
    @cuda blocks = blocks threads = threads update_set_kernel!(mask, set, best, x_bin)
    left, right = set[mask], set[.!mask]
    return left, right
end

# operate on hist_gpu
"""
find_split_gpu!
    Find best split over gpu histograms
"""

function find_split_gpu!(hist::AbstractArray{T,4}, edges::Vector{Vector{T}}, 𝑗::AbstractVector{S}, depth, params::EvoTypes) where {T,S}

    hist_cum_L = cumsum(hist, dims=2)
    # hist_cum_R = sum(hist, dims=2) .- hist_cum_L
    hist_cum_R = hist_cum_L[:,end:end,:] .- hist_cum_L
    
    gains_L = get_hist_gains_gpu(hist_cum_L[:,1:(end - 1),:], 𝑗, params.λ, depth)
    gains_R = get_hist_gains_gpu(hist_cum_R[:,1:(end - 1),:], 𝑗, params.λ, depth)
    gains = gains_L + gains_R

    best = findmax(gains)
    gain, bin, feat = best[1], best[2][1], UInt32(best[2][2])
    cond = edges[feat][bin]
    # gainL, gainR = gains_L[bin, feat], gains_R[bin, feat]
    gainL, gainR = Array(gains_L)[bin, feat], Array(gains_R)[bin, feat]

    # ∑L = hist_cum_L[:, bin, feat]
    # ∑R = hist_cum_R[:, bin, feat]
    ∑L = Array(hist_cum_L[:, bin, feat])
    ∑R = Array(hist_cum_R[:, bin, feat])

    return (gain = gain, bin = bin, feat = feat, cond = cond,
        gainL = gainL, gainR = gainR,
        ∑L = ∑L, ∑R = ∑R)
end


function hist_gains_gpu!(gains::CuDeviceMatrix{T}, h::CuDeviceArray{T,3}, 𝑗::CuDeviceVector{S}, λ::T) where {T,S}
    
    i = threadIdx().x
    j = 𝑗[blockIdx().x]
    n = 𝑗[blockIdx().y]
    K = (size(h, 1) - 1) ÷ 2

    @inbounds 𝑤 = h[2 * K + 1, i, j]     
    if 𝑤 > 1e-1
        @inbounds for k in 1:K
            if k == 1
                gains[i, j, n] = (h[k, i, j, n]^2 / (h[2 * K + k - 1, i, j, n] + λ * 𝑤)) / 2
            else
                gains[i, j, n] += (h[k, i, j, n]^2 / (h[2 * K + k - 1, i, j, n] + λ * 𝑤)) / 2
            end
        end
    end

    return nothing
end

function get_hist_gains_gpu(h::CuArray{T,4}, 𝑗::CuVector{S}, λ::T, depth; MAX_THREADS=1024) where {T,S}
    
    gains = CUDA.fill(T(-Inf), size(h, 2) - 1, size(h, 3), size(h, 4))
    
    thread_i = min(size(gains, 1), MAX_THREADS)
    threads = thread_i
    blocks = length(𝑗), 2^(depth - 1)

    @cuda blocks = blocks threads = threads hist_gains_gpu!(gains, h, 𝑗, λ)
    return gains
end
