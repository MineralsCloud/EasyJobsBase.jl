using Thinkers: TimeoutException, ErrorInfo, reify!, setargs!, haserred, _kill

export run!, execute!, kill!

# See https://github.com/MineralsCloud/SimpleWorkflows.jl/issues/137
"""
    Executor(job::AbstractJob; wait=false, maxattempts=1, interval=1, delay=0)

Handle the execution of jobs.

# Arguments
- `job::AbstractJob`: an `AbstractJob` instance.
- `wait::Bool=false`: determines whether to wait for the job to complete before executing the next task.
- `maxattempts::UInt64=1`: the maximum number of attempts to execute the job.
- `interval::Real=1`: the time interval between each attempt to execute the job, in seconds.
- `delay::Real=0`: the delay before the first attempt to execute the job, in seconds.
"""
mutable struct Executor{T<:AbstractJob}
    job::T
    wait::Bool
    maxattempts::UInt64
    interval::Real
    delay::Real
    task::Task
    function Executor(job::T; wait=false, maxattempts=1, interval=1, delay=0) where {T}
        @assert maxattempts >= 1
        @assert interval >= zero(interval)
        @assert delay >= zero(delay)
        return new{T}(job, wait, maxattempts, interval, delay, @task _run!(job))
    end
end

function newtask!(exec::Executor)
    exec.task = @task _run!(exec.job)  # Start a new task. This is necessary for rerunning!
    return exec
end

"""
    run!(job::Job; wait=false, maxattempts=1, interval=1, delay=0)

Run a `Job` with a maximum number of attempts, with each attempt separated by `interval` seconds
and an initial `delay` in seconds.
"""
function run!(job::AbstractJob; kwargs...)
    @assert shouldrun(job)
    prepare!(job)
    exec = Executor(job; kwargs...)
    execute!(exec)
    return exec
end

"""
    execute!(exec::Executor)

Execute a given job associated with the `Executor` object.

This function checks if the job has succeeded. If not, it sleeps for a delay,
runs the job once using `singlerun!`. If `maxattempts` is more than ``1``, it loops over
the remaining attempts, sleeping for an interval, running the job, and waiting in each loop.
If the job has already succeeded, it stops immediately.

# Arguments
- `exec::Executor`: the `Executor` object containing the job to be executed.
"""
function execute!(exec::Executor)
    if !issucceeded(exec.job)
        sleep(exec.delay)
        singlerun!(exec)  # Wait or not depends on `exec.wait`
        if exec.maxattempts > 1
            wait(exec)
            for _ in Base.OneTo(exec.maxattempts - 1)
                sleep(exec.interval)
                singlerun!(exec)
                wait(exec)  # Wait no matter whether `exec.wait` is `true` or `false`
            end
        end
    end
    return exec  # Stop immediately if the job has succeeded
end

"""
    singlerun!(exec::Executor)

Executes a single run of the job associated with the `Executor` object.

This function checks the job status. If the job is pending, it schedules the task and waits
if `wait` is `true`. If the job has failed or been interrupted, it creates a new task,
resets the job status to `PENDING`, and then calls `singlerun!` again. If the job is running
or has succeeded, it does nothing and returns the `Executor` object.
"""
function singlerun!(exec::Executor)
    if ispending(exec.job)
        schedule(exec.task)
        if exec.wait
            wait(exec)
        end
    end
    if isfailed(exec.job) || isinterrupted(exec.job)
        newtask!(exec)
        exec.job.status = PENDING
        return singlerun!(exec)  # Wait or not depends on `exec.wait`
    end
    return exec  # Do nothing for running and succeeded jobs
end

# Internal function to execute a specific `AbstractJob`.
function _run!(job::AbstractJob)  # Do not export!
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

prepare!(::AbstractJob) = nothing  # No op
function prepare!(job::ArgDependentJob)
    # Use previous results as arguments
    args = if countparents(job) == 1
        something(getresult(only(eachparent(job))))
    else  # > 1
        Set(something(getresult(parent)) for parent in eachparent(job))
    end
    setargs!(job.core, args)
    return nothing
end

shouldrun(::AbstractJob) = true
shouldrun(job::ConditionalJob) =
    countparents(job) >= 1 && all(issucceeded(parent) for parent in eachparent(job))
shouldrun(job::ArgDependentJob) = countparents(job) >= 1

"""
    kill!(exec::Executor)

Manually kill a `Job`, works only if it is running.
"""
function kill!(exec::Executor)
    if isexited(exec.job)
        @info "the job $(exec.job.id) has already exited!"
    elseif ispending(exec.job)
        @info "the job $(exec.job.id) has not started!"
    else
        _kill(exec.task)
    end
    return exec
end

"""
    Base.wait(exec::Executor)

Overloads the Base `wait` function to wait for the `Task` associated with an `Executor`
object to complete.
"""
Base.wait(exec::Executor) = wait(exec.task)
