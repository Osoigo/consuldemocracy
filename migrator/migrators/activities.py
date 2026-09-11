from ..models.new_models.activity import NewActivity
from ..models.old_models.activity import OldActivity


async def migrate(id_maps, migration_stats):
    stats = {
        "total": 0,
        "migrated": 0,
        "missing_budget_investments": set(),
        "missing_newsletters": set(),
        "missing_users": set(),
        "unsupported_actionable_type": set(),
    }
    total_old_activities = await OldActivity.all().count()
    for i in range(0, total_old_activities, 10000):
        old_activities = await OldActivity.all().order_by("id")[i : i + 10000]

        for old_activity in old_activities:
            stats["total"] += 1
            if old_activity.actionable_type == "Budget::Investment":
                actionable_id = id_maps["budget_investments"].get(
                    str(old_activity.actionable_id)
                )
                if actionable_id is None:
                    # print(
                    #     f"Missing budget investment. Old id: {old_activity.actionable_id}"
                    # )
                    stats["missing_budget_investments"].add(old_activity.actionable_id)
                    continue
            elif old_activity.actionable_type == "Newsletter":
                actionable_id = id_maps["newsletters"].get(
                    str(old_activity.actionable_id)
                )
                if actionable_id is None:
                    # print(f"Missing newsletter. Old id: {old_activity.actionable_id}")
                    stats["missing_newsletters"].add(old_activity.actionable_id)
                    continue
            else:
                # print(f"Actividad en tipo no soportado: {old_activity.actionable_type}")
                stats["unsupported_actionable_type"].add(old_activity.actionable_type)
                continue

            user_id = id_maps["users"].get(str(old_activity.user_id))
            if user_id is None:
                stats["missing_users"].add(old_activity.user_id)
                continue

            new_activity = NewActivity(
                user_id=user_id,
                action=old_activity.action,
                actionable_type=old_activity.actionable_type,
                actionable_id=actionable_id,
                created_at=old_activity.created_at,
            )

            new_activity.updated_at = old_activity.updated_at

            await new_activity.save()
            stats["migrated"] += 1

    stats["missing_budget_investments"] = list(stats["missing_budget_investments"])
    stats["missing_newsletters"] = list(stats["missing_newsletters"])
    stats["missing_users"] = list(stats["missing_users"])
    stats["unsupported_actionable_type"] = list(stats["unsupported_actionable_type"])
    migration_stats["activities"] = stats
