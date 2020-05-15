export A2CLearner

using Flux

"""
    A2CLearner(;kwargs...)

# Keyword arguments

- `approximator`::[`ActorCritic`](@ref)
- `γ::Float32`, reward discount rate.
- `actor_loss_weight::Float32`
- `critic_loss_weight::Float32`
- `entropy_loss_weight::Float32`
"""
Base.@kwdef struct A2CLearner{A<:ActorCritic} <: AbstractLearner
    approximator::A
    γ::Float32
    actor_loss_weight::Float32
    critic_loss_weight::Float32
    entropy_loss_weight::Float32
end

(learner::A2CLearner)(obs::BatchObs) =
    learner.approximator.actor(send_to_device(
        device(learner.approximator),
        get_state(obs),
    )) |> send_to_host

function RLBase.update!(learner::A2CLearner, t::AbstractTrajectory)
    isfull(t) || return

    states = get_trace(t, :state)
    actions = get_trace(t, :action)
    rewards = get_trace(t, :reward)
    terminals = get_trace(t, :terminal)
    next_state = select_last_frame(get_trace(t, :next_state))

    AC = learner.approximator
    γ = learner.γ
    w₁ = learner.actor_loss_weight
    w₂ = learner.critic_loss_weight
    w₃ = learner.entropy_loss_weight

    states = send_to_device(device(AC), states)
    next_state = send_to_device(device(AC), next_state)

    states_flattened = flatten_batch(states) # (state_size..., n_thread * update_step)
    actions = flatten_batch(actions)
    actions = CartesianIndex.(actions, 1:length(actions))

    next_state_values = AC.critic(next_state)
    gains = discount_rewards(
        rewards,
        γ;
        dims = 2,
        init = send_to_host(next_state_values),
        terminal = terminals,
    )
    gains = send_to_device(device(AC), gains)

    gs = gradient(Flux.params(AC)) do
        probs = AC.actor(states_flattened)
        log_probs = log.(probs)
        log_probs_select = log_probs[actions]
        values = AC.critic(states_flattened)
        advantage = vec(gains) .- vec(values)
        actor_loss = -mean(log_probs_select .* Zygote.dropgrad(advantage))
        critic_loss = mean(advantage .^ 2)
        entropy_loss = sum(probs .* log_probs) * 1 // size(probs, 2)
        loss = w₁ * actor_loss + w₂ * critic_loss - w₃ * entropy_loss
        loss
    end
    update!(AC, gs)
end

function (agent::Agent{<:QBasedPolicy{<:A2CLearner},<:CircularCompactSARTSATrajectory})(
    ::PreActStage,
    obs,
)
    action = agent.policy(obs)
    state = get_state(obs)
    push!(agent.trajectory; state = state, action = action)
    update!(agent.policy, agent.trajectory)

    # the main difference is we'd like to flush the buffer after each update!
    if isfull(agent.trajectory)
        empty!(agent.trajectory)
        push!(agent.trajectory; state = state, action = action)
    end

    action
end
