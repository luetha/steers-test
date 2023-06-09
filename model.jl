using JuMP
using Clp
using Plots
using DataFrames, CSV
include("helper_functions.jl")

data_path = "data"
time_series = CSV.read(joinpath(data_path, "timedata.csv"),DataFrame)
tech_data = CSV.read(joinpath(data_path, "technologies.csv"),DataFrame)

### data preprocessing ###
T = 1:size(time_series, 1) |> collect
P = tech_data[:,:technology] |> Vector
DISP = tech_data[tech_data[!,:dispatchable] .== 1, :technology]
NONDISP = tech_data[tech_data[!,:dispatchable] .== 0 ,:technology]
S = tech_data[tech_data[!,:investment_storage] .> 0 ,:technology]

### parameters ###
annuity_factor(n,r) = r * (1+r)^n / (((1+r)^n)-1)

interest_rate = 0.04
ic_generation_cap = Dict{String, Float64}()
ic_charging_cap = Dict{String, Float64}()
ic_storage_cap = Dict{String, Float64}()
eff_in = Dict{String, Float64}()
eff_out = Dict{String, Float64}()
vc = Dict{String, Float64}()

for row in eachrow(tech_data)
    af = annuity_factor(row.lifetime, interest_rate)
    ic_generation_cap[row.technology] = row.investment_generation * af

    iccc = row.investment_charge * af
    iccc > 0 && (ic_charging_cap[row.technology] = iccc)

    icsc = row.investment_storage * af
    icsc > 0 && (ic_storage_cap[row.technology] = icsc)

    row.storage_efficiency_in > 0 && (eff_in[row.technology] = row.storage_efficiency_in)
    row.storage_efficiency_out > 0 && (eff_out[row.technology] = row.storage_efficiency_out)

    vc[row.technology] = row.vc
end

demand = time_series[:,:demand] |> Vector
availability = Dict(nondisp => time_series[:,nondisp] for nondisp in NONDISP)

successor(arr, x) = (x == length(arr)) ? 1 : x + 1
dispatch_scale = 8760/length(T)

### model ###
m = Model(Clp.Optimizer)

@variables m begin
    # variables for dispatch model
    G[DISP, T] >= 0
    CU[T] >= 0
    D_stor[S,T] >= 0
    L_stor[S,T] >= 0

    # variables for capacity expansion model
    CAP_G[P] >= 0
    CAP_D[S] >= 0
    CAP_L[S] >= 0
end

@objective(m, Min,
    sum(vc[disp] * G[disp,t] for disp in DISP, t in T) * dispatch_scale
    + sum(ic_generation_cap[p] * CAP_G[p] for p in P)
    + sum(ic_charging_cap[s] * CAP_D[s] for s in S if haskey(ic_charging_cap, s))
    + sum(ic_storage_cap[s] * CAP_L[s] for s in S)
)

@expression(
    m, feed_in[ndisp=NONDISP, t=T],
    availability[ndisp][t]*CAP_G[ndisp]
)

@constraint(m, ElectricityBalance[t=T],
    sum(G[disp,t] for disp in DISP)
    + sum(feed_in[ndisp,t] for ndisp in NONDISP)
    - sum(D_stor[s,t] for s in S)
    - CU[t]
    ==
    demand[t]
)

@constraint(m, MaxGeneration[disp=DISP, t=T],
    G[disp,t] <= CAP_G[disp]
)

@constraint(m, MaxCharge[s=S, t=T; haskey(ic_charging_cap, s)],
    D_stor[s,t] <= CAP_D[s]
)

@constraint(m, SymmetricChargingPower[s=S, t=T; !(haskey(ic_charging_cap, s))],
    CAP_G[s] == CAP_D[s]
)

@constraint(m, MaxLevel[s=S, t=T],
    L_stor[s,t] <= CAP_L[s]
)

@constraint(m, StorageLevel[s=S, t=T],
    L_stor[s, successor(T,t)]
    ==
    L_stor[s, t]
    + eff_in[s]*D_stor[s,t]
    - (1/eff_out[s]) * G[s,t]
)

optimize!(m)


######

colordict = Dict(
    "pv" => :yellow,
    "wind" => :lightblue,
    "seasonal_storage" => :darkblue,
    "battery" => :lightgrey,
    "demand" => :darkgrey,
    "curtailment" => :red
)

######## plot electricity balance ###########

result_G = get_result(G, [:technology, :hour])
result_feed_in = get_result(feed_in, [:technology, :hour])

result_charging = get_result(D_stor, [:technology, :hour])
result_CU = get_result(CU, [:hour])
result_CU[!,:technology] .= "curtailment"
df_demand = DataFrame(hour=T, technology="demand", value=demand)

result_generation = vcat(result_feed_in, result_G)
result_demand = vcat(result_charging, result_CU, df_demand)

table_gen = unstack(result_generation, :hour, :technology, :value)
table_gen = table_gen[!,[NONDISP..., DISP...]]
labels = names(table_gen) |> permutedims
colors = [colordict[tech] for tech in labels]
data_gen = Array(table_gen)

balance_plot = areaplot(
    data_gen,
    label=labels,
    color=colors,
    width=0,
    leg=:outertopright
)

table_dem = unstack(result_demand, :hour, :technology, :value)
table_dem = table_dem[!,["demand", S...,"curtailment"]]
labels2 = names(table_dem) |> permutedims
colors2 = [colordict[tech] for tech in labels2]
replace!(labels2, [item => "" for item in intersect(labels2, labels)]...)
data_dem = -Array(table_dem)

areaplot!(
    balance_plot,
    data_dem,
    label=labels2,
    color=colors2,
    width=0,
    leg=:outertopright
)

hline!(balance_plot, [0], color=:black, label="", width=2)

#################################

df_installed_gen = get_result(CAP_G, [:technology])
x = df_installed_gen[!,:technology]
y = df_installed_gen[!,:value] ./ 1000
p1 = bar(
    x,
    y,
    leg=false,
    title="Installed power generation",
    ylabel="GW",
    guidefontsize=8,
    rotation=45
)

df_installed_charge = get_result(CAP_D, [:technology])
x = df_installed_charge[!,:technology]
y = df_installed_charge[!,:value] ./ 1000
p2 = bar(
    x,
    y,
    leg=false,
    title="Installed power charging",
    ylim=ylims(p1),
    rotation=45
)

df_installed_storage = get_result(CAP_L, [:technology])
x = df_installed_storage[!,:technology]
y = df_installed_storage[!,:value] ./ 1e6

p3 = bar(
    x,
    y,
    leg=false,
    title="Installed storage capacity",
    ylabel="TWh",
    guidefontsize=8,
    rotation=45
)

plot(
    p1,
    p2,
    p3,
    layout=(1,3),
    titlefontsize=8,
    tickfontsize=6
)