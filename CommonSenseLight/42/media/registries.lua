-- Custom body locations for duffel bags / ALICE rigs (used by ClimbWithBags and GearSling).
CustomBodyLocation = CustomBodyLocation or {}
CustomBodyLocation.ItemBodyLocation = CustomBodyLocation.ItemBodyLocation or {}
if not CustomBodyLocation.ItemBodyLocation.LowerBack then
    CustomBodyLocation.ItemBodyLocation.LowerBack = ItemBodyLocation.register("custombodylocation:LowerBack")
end
if not CustomBodyLocation.ItemBodyLocation.NewRigLocation then
    CustomBodyLocation.ItemBodyLocation.NewRigLocation = ItemBodyLocation.register("custombodylocation:NewRigLocation")
end
