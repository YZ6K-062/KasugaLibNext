package lib.kasuga.create.content.train.event;

import com.simibubi.create.content.trains.entity.Carriage;
import com.simibubi.create.content.trains.graph.DimensionPalette;
import com.simibubi.create.content.trains.graph.TrackGraph;
import net.minecraft.core.HolderLookup;
import net.minecraft.nbt.CompoundTag;
import net.neoforged.bus.api.Event;

public class CarriageLoadEvent extends Event {

    public Carriage carriage;
    public HolderLookup.Provider registries;
    public CompoundTag nbt;
    public DimensionPalette dimensions;
    public TrackGraph graph;

    public CarriageLoadEvent(Carriage carriage, HolderLookup.Provider registries, CompoundTag nbt,  DimensionPalette dimensions, TrackGraph graph) {
        this.carriage = carriage;
        this.registries = registries;
        this.nbt = nbt;
        this.dimensions = dimensions;
        this.graph = graph;
    }
}
