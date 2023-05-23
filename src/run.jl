using Dates: Period, now

using Thinkers: TimeoutException, ErrorInfo, reify!, setargs!, haserred, _kill

export run!, start!, kill!

"""
    run!(job::Job; maxattempts=1, interval=1, waitfor=0)

Run a `Job` with a maximum number of attempts, with each attempt separated by a few seconds.
"""
function run!(job::AbstractJob; kwargs...)
    exe = Executor(job; kwargs...)
    start!(exe)
    return exe
end

function start!(exe::Executor)
    @assert isreadytorun(exe)
    return _run!(exe)
end
function start!(exe::Executor{StronglyDependentJob})
    @assert isreadytorun(exe)
    parents = exe.job.parents
    # Use previous results as arguments
    args = if length(parents) == 1
        something(getresult(first(parents)))
    else  # > 1
        (Set(something(getresult(parent)) for parent in parents),)
    end
    setargs!(exe.job.core, args)
    return _run!(exe)
end

function _run!(exe::Executor)  # Do not export!
    sleep(exe.waitfor)
    for _ in exe.maxattempts
        __run!(exe)
        if issucceeded(exe.job)
            return exe  # Stop immediately
        else
            sleep(exe.interval)
        end
    end
end

function __run!(exe::Executor)  # Do not export!
    if ispending(exe.job)
        schedule(exe.task)
    else
        exe.job.status = PENDING
        return __run!(exe)
    end
end

function ___run!(job::AbstractJob)  # Do not export!
    job.status = RUNNING
    job.start_time = now()
    reify!(job.core)
    job.end_time = now()
    job.status = if haserred(job.core)
        e = something(getresult(job.core)).thrown
        e isa Union{InterruptException,TimeoutException} ? INTERRUPTED : FAILED
    else
        SUCCEEDED
    end
    job.count += 1
    return job
end

isreadytorun(::Executor) = true
isreadytorun(exe::Executor{<:DependentJob}) =
    length(exe.job.parents) >= 1 && all(issucceeded(parent) for parent in exe.job.parents)

"""
    kill!(exe::Executor)

Manually kill a `Job`, works only if it is running.
"""
function kill!(exe::Executor)
    if isexited(exe.job)
        @info "the job $(exe.job.id) has already exited!"
    elseif ispending(exe.job)
        @info "the job $(exe.job.id) has not started!"
    else
        _kill(exe.task)
    end
    return exe
end

Base.wait(exe::Executor) = wait(exe.task)
