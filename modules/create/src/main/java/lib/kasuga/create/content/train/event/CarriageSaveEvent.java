package lib.kasuga.create.content.train.event;

import com.simibubi.create.content.trains.entity.Carriage;
import com.simibubi.create.content.trains.graph.DimensionPalette;
import net.minecraft.core.HolderLookup;
import net.minecraft.nbt.CompoundTag;
import net.neoforged.bus.api.Event;

public class CarriageSaveEvent extends Event {

    public Carriage carriage;
    public DimensionPalette dimensions;
    public HolderLookup.Provider registries;
    public CompoundTag nbt;

    public CarriageSaveEvent(Carriage carriage, DimensionPalette dimensions, HolderLookup.Provider registries, CompoundTag nbt) {
        this.carriage = carriage;
        this.dimensions = dimensions;
        this.registries = registries;
        this.nbt = nbt;
    }
}
