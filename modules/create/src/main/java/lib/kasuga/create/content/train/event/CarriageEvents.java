package lib.kasuga.create.content.train.event;

import com.simibubi.create.content.trains.entity.Carriage;
import com.simibubi.create.content.trains.entity.CarriageBogey;
import lib.kasuga.create.CreateConfig;
import lib.kasuga.create.content.train.CarriageAccess;
import net.minecraft.core.BlockPos;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.ListTag;
import net.minecraft.nbt.NbtUtils;
import net.minecraft.nbt.Tag;
import net.neoforged.bus.api.SubscribeEvent;
import net.neoforged.fml.common.EventBusSubscriber;
import org.spongepowered.asm.mixin.Unique;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

@EventBusSubscriber
public class CarriageEvents {

    private static final String KSG_REDUNDANT_BOGEYS_KEY = "KasugaRedundantBogeys";

    private static final String KSG_CONTENT_KEY = "KasugaContent";

    private static final String KSG_Y_OFFSET_KEY = "KasugaYOffset";


    @SubscribeEvent
    public static void onCarriageLoadEvent(CarriageLoadEvent event) {
        CompoundTag nbt = event.nbt;
        if (!nbt.contains(KSG_CONTENT_KEY)) return;
        nbt = nbt.getCompound(KSG_CONTENT_KEY);
        Carriage carriage = event.carriage;
        if (CreateConfig.isCarriageYOffestEnabled()) {
            ((CarriageAccess) carriage).kasuga$restoreYOffset(nbt.getFloat(KSG_Y_OFFSET_KEY));
        }
        if (!CreateConfig.isMultiBogeyCarriageEnabled())
            return;
        ListTag tuples = nbt.getList(KSG_REDUNDANT_BOGEYS_KEY, Tag.TAG_COMPOUND);
        if (tuples.isEmpty())
            return;
        List<CarriageBogey> bogeys = new ArrayList<>(tuples.size());
        List<BlockPos> positions = new ArrayList<>(tuples.size());
        for (int i = 0; i < tuples.size(); i++) {
            CompoundTag tuple = tuples.getCompound(i);
            Optional<BlockPos> position = NbtUtils.readBlockPos(tuple, "Position");
            if (position.isEmpty())
                continue;
            CarriageBogey bogey = CarriageBogey.read(tuple.getCompound("BogeyData"), event.graph, event.dimensions);
            bogey.carriage = carriage;
            bogeys.add(bogey);
            positions.add(position.get());
        }

        CarriageAccess access = (CarriageAccess) carriage;
        access.kasuga$addRedundantBogeys(bogeys);
        access.kasuga$addRedundantBogeyPositions(positions);
    }

    @SubscribeEvent
    public static void onCarriageSaveEvent(CarriageSaveEvent event) {
        CompoundTag parentTag = event.nbt;
        CompoundTag tag = new CompoundTag();
        parentTag.put(KSG_CONTENT_KEY, tag);
        CarriageAccess access = (CarriageAccess) event.carriage;
        if (CreateConfig.isCarriageYOffestEnabled() && access.kasuga$getYOffset() != 0)
            tag.putFloat(KSG_Y_OFFSET_KEY, access.kasuga$getYOffset());
        if (!CreateConfig.isMultiBogeyCarriageEnabled())
            return;
        List<CarriageBogey> bogeys = access.kasuga$getRedundantBogeys();
        List<BlockPos> positions = access.kasuga$getRedundantBogeyPositions();
        int count = Math.min(bogeys.size(), positions.size());
        if (count == 0)
            return;

        ListTag tuples = new ListTag();
        for (int i = 0; i < count; i++) {
            CompoundTag tuple = new CompoundTag();
            tuple.put("BogeyData", bogeys.get(i).write(event.dimensions));
            tuple.put("Position", NbtUtils.writeBlockPos(positions.get(i)));
            tuples.add(tuple);
        }
        tag.put(KSG_REDUNDANT_BOGEYS_KEY, tuples);
    }
}
