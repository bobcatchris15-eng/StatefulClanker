# Optional machine/project routing hints layered over ordinary provider CLI config.
# The conversational planner assigns task.size semantically; the runtime only maps
# that declared class to a configured CLI provider when a mapping exists.

function Resolve-SCProvider($Task,[string]$Override,[string]$Stage='worker') {
    $cfg=Get-SCConfig;$name=$null
    if($Override){
        $name=$Override
    } elseif($Stage-eq'critic'-and$cfg.PSObject.Properties['criticProvider']-and$cfg.criticProvider){
        $name=[string]$cfg.criticProvider
    } elseif($Stage-eq'validator'-and$cfg.PSObject.Properties['validatorProvider']-and$cfg.validatorProvider){
        $name=[string]$cfg.validatorProvider
    } elseif($Task.provider){
        $name=[string]$Task.provider
    } elseif($Stage-eq'worker'-and$cfg.PSObject.Properties['providerBySize']-and$cfg.providerBySize) {
        $size=if($Task.PSObject.Properties['size']-and$Task.size){[string]$Task.size}else{'small'}
        $route=$cfg.providerBySize.PSObject.Properties[$size]
        if($route-and-not[string]::IsNullOrWhiteSpace([string]$route.Value)){$name=[string]$route.Value}
    }
    if([string]::IsNullOrWhiteSpace($name)){$name=[string]$cfg.defaultProvider}
    $property=$cfg.providers.PSObject.Properties[$name]
    if($null-eq$property){throw "Provider '$name' not configured."}
    return [ordered]@{name=$name;config=$property.Value}
}
