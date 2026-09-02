import re
import time
import uuid

from src.model.utils.db_operations import db_operations


class UserProfileMemory:
    INTERROGATIVE_VALUES = {"what", "who", "which", "where", "什么", "谁", "哪个", "哪里", "哪天"}
    REQUIRED_FIELDS = {
        "age": "年龄",
        "sex": "性别",
        "height_cm": "身高",
        "weight_kg": "体重",
        "goal": "当前目标",
    }
    FIELD_TERMS = {
        "name": ("名字", "姓名", "my name", "name is"),
        "age": ("年龄", "岁", "age"),
        "sex": ("性别", "男性", "女性", "男", "女", "sex"),
        "height_cm": ("身高", "cm", "厘米", "height"),
        "weight_kg": ("体重", "kg", "公斤", "重量", "weight"),
        "goal": ("目标", "goal"),
        "dietary_preferences": ("饮食限制", "饮食偏好", "diet"),
        "training_preferences": ("训练偏好", "训练安排", "training"),
        "physiological_factors": ("身体因素",),
        "health_conditions": ("健康情况", "疾病", "condition"),
        "medications": ("用药", "药物", "medication"),
    }
    LIST_FIELDS = {
        "dietary_preferences",
        "training_preferences",
        "physiological_factors",
        "health_conditions",
        "medications",
    }
    SUPPLEMENTS_NOT_MEDICATIONS = {"肌酸", "维生素D", "维生素", "鱼油", "蛋白粉", "乳清蛋白", "一水肌酸"}

    def __init__(self, redis_config, user_id):
        self.redis_config = redis_config
        self.user_id = user_id

    def promote_facts(self, user_text, profile_update=None, request_id=None):
        before_profile = db_operations.load_user_profile(self.redis_config, self.user_id)
        forgotten_fields = self._requested_forgetting(user_text)
        if forgotten_fields:
            db_operations.delete_memory_facts(self.redis_config, self.user_id, forgotten_fields)
            db_operations.delete_user_profile_fields(self.redis_config, self.user_id, forgotten_fields)
            db_operations.save_forgotten_profile_fields(self.redis_config, self.user_id, forgotten_fields)
            self._audit_profile_change(
                "forget",
                {field: before_profile.get(field) for field in sorted(forgotten_fields)},
                user_text,
                request_id,
            )

        patterns = {
            "name": r"\bmy name is\s+([^,.!?;]+)",
            "profession": r"\bi (?:am|work as|work in)\s+(?:a |an )?([^,.!?;]+)",
            "preference": r"\bi (?:prefer|like|love)\s+([^,.!?;]+)",
        }
        facts = {}
        for name, pattern in patterns.items():
            match = re.search(pattern, user_text, flags=re.IGNORECASE)
            if match:
                facts[name] = match.group(1).strip()
        chinese_name = re.search(
            r"(?:我叫|我的名字是)\s*(?!什么|啥|谁|哪位)([^，。；！？\s]{1,24})(?=[，。；！？\s]|$)",
            user_text,
        )
        chinese_profession = re.search(r"(?:我的职业是|我从事)\s*([^，。；！？]{2,24})", user_text)
        if chinese_name:
            facts["name"] = chinese_name.group(1).strip()
        if chinese_profession:
            facts["profession"] = chinese_profession.group(1).strip()
        chinese_profile = {}
        age = re.search(
            r"(?:(?:我|本人)(?:今年)?|(?:^|[，,；;])\s*年龄\s*(?:是|为)?)\s*(\d{1,3})\s*岁",
            user_text,
        )
        if not age:
            age = re.search(r"(?:^|[，,；;])\s*今年\s*(\d{1,3})\s*岁", user_text)
        sex = re.search(
            r"(?:(?:我|本人)是|(?:^|[，,；;])\s*性别\s*(?:是|为)?)\s*(女性|女生|女|男性|男生|男)(?=[，。；！？,\s]|$)",
            user_text,
        )
        height = re.search(
            r"(?:(?:我(?:的)?|本人)\s*身高|(?:^|[，,；;])\s*身高)\s*(?:是|为)?\s*(\d+(?:\.\d+)?)\s*(?:cm|厘米)",
            user_text,
            flags=re.IGNORECASE,
        )
        weight = re.search(
            r"(?:(?:我(?:的)?|本人)\s*体重|(?:^|[，,；;])\s*体重)\s*(?:是|为)?\s*(\d+(?:\.\d+)?)\s*(?:kg|公斤)",
            user_text,
            flags=re.IGNORECASE,
        )
        if not weight:
            weight = re.search(
                r"(?:我(?:刚才)?(?:的)?体重|刚才(?:我(?:的)?)?体重)[^，。；！？]{0,20}(?:说错|更正|改成|改为|应该是)[^\d]{0,8}(\d+(?:\.\d+)?)\s*(?:kg|公斤)",
                user_text,
                flags=re.IGNORECASE,
            )
        if chinese_name:
            listed_age = re.search(r"(?:^|[，,；;])\s*(\d{1,3})\s*岁", user_text)
            listed_sex = re.search(r"(?:^|[，,；;])\s*(女性|女生|女|男性|男生|男)(?=[，。；！？,\s]|$)", user_text)
            listed_height = re.search(r"(?:^|[，,；;])\s*(\d+(?:\.\d+)?)\s*(?:cm|厘米)", user_text, flags=re.IGNORECASE)
            listed_weight = re.search(r"(?:^|[，,；;])\s*(\d+(?:\.\d+)?)\s*(?:kg|公斤)", user_text, flags=re.IGNORECASE)
            age = age or listed_age
            sex = sex or listed_sex
            if listed_height and listed_weight:
                height = height or listed_height
                weight = weight or listed_weight
        goal = re.search(
            r"目标\s*(?:是|为)?\s*((?!吗|呢|什么|如何|怎么)[^，。；！？\s]+)",
            user_text,
        )
        if age:
            chinese_profile["age"] = age.group(1)
        if sex:
            chinese_profile["sex"] = sex.group(1)
        if height:
            chinese_profile["height_cm"] = height.group(1)
        if weight:
            chinese_profile["weight_kg"] = weight.group(1)
        if goal:
            chinese_profile["goal"] = goal.group(1)
        if not re.search(r"[吗么呢？?]", user_text):
            optional_patterns = {
                "dietary_preferences": (
                    r"(?:饮食(?:限制|偏好)\s*(?:是|为)?|(?:我|本人)?偏爱)\s*([^，。；！？]{1,80})",
                    r"((?:乳糖|麸质|坚果|海鲜)[^，。；！？]{0,20}(?:不耐受|过敏))",
                ),
                "training_preferences": (r"训练偏好\s*(?:是|为)?\s*([^，。；！？]{1,80})",),
                "physiological_factors": (r"([^，。；！？]{1,40}(?:不适|受伤|伤病))",),
                "health_conditions": (r"((?:没有|无)(?:已知)?(?:慢性病|基础疾病|健康问题)|(?:有|患有)[^，。；！？]{1,40}(?:病|疾病))",),
                "medications": (r"((?:没|没有|未|无)(?:在)?用药|(?:正在|目前)?(?:服用|使用)[^，。；！？]{1,40}(?:药|药物))",),
            }
            for field, patterns in optional_patterns.items():
                values = [match.group(1).strip() for pattern in patterns if (match := re.search(pattern, user_text))]
                if values:
                    chinese_profile[field] = values
        db_operations.save_memory_facts(self.redis_config, self.user_id, facts)
        extracted_profile = dict(profile_update or {})
        for field in ("age", "sex", "height_cm", "weight_kg"):
            if field not in chinese_profile:
                extracted_profile.pop(field, None)
        extracted_profile.update(chinese_profile)
        profile = self.normalize_profile_update(extracted_profile)
        if profile:
            db_operations.save_user_profile(self.redis_config, self.user_id, profile)
            changed = {
                field: value
                for field, value in profile.items()
                if before_profile.get(field) != value
            }
            if changed:
                self._audit_profile_change(
                    "profile_extraction" if profile_update else "pattern_extraction",
                    changed,
                    user_text,
                    request_id,
                )
        return facts

    def _audit_profile_change(self, source, fields, user_text, request_id):
        db_operations.append_profile_audit(
            self.redis_config,
            self.user_id,
            {
                "id": uuid.uuid4().hex,
                "recorded_at_ms": int(time.time() * 1000),
                "source": source,
                "request_id": request_id,
                "fields": fields,
                "evidence_text": str(user_text).strip(),
                "schema_version": 4,
            },
        )

    def _requested_forgetting(self, user_text):
        text = str(user_text).strip()
        if not re.search(r"(?:忘掉|忘记|删除|删掉|清除|移除|不要记得|不要再记)", text):
            return set()
        return {field for field, terms in self.FIELD_TERMS.items() if any(term in text for term in terms)}

    def forgotten_fields(self):
        return db_operations.load_forgotten_profile_fields(self.redis_config, self.user_id)

    def forgotten_terms(self):
        return tuple(
            term.lower()
            for field in self.forgotten_fields()
            for term in self.FIELD_TERMS.get(field, ())
        )

    def normalize_profile_update(self, profile_update):
        profile = {}
        if not isinstance(profile_update, dict):
            return profile
        if profile_update.get("name"):
            name = str(profile_update["name"]).strip()[:80]
            if name.lower() not in self.INTERROGATIVE_VALUES:
                profile["name"] = name
        if profile_update.get("birth_date"):
            birth_date = str(profile_update["birth_date"]).strip()[:32]
            if re.fullmatch(r"\d{4}-\d{2}-\d{2}", birth_date):
                profile["birth_date"] = birth_date
        for key in ("age", "height_cm", "weight_kg"):
            if profile_update.get(key) in (None, ""):
                continue
            try:
                value = float(profile_update[key])
            except (TypeError, ValueError):
                continue
            profile[key] = int(value) if key == "age" else value
        if profile_update.get("sex") in ("male", "female", "男", "女", "男性", "女性", "男生", "女生"):
            profile["sex"] = {
                "男": "male",
                "男性": "male",
                "男生": "male",
                "女": "female",
                "女性": "female",
                "女生": "female",
            }.get(profile_update["sex"], profile_update["sex"])
        if profile_update.get("goal"):
            profile["goal"] = str(profile_update["goal"]).strip()
        if profile_update.get("personal_context"):
            personal_context = profile_update["personal_context"]
            if isinstance(personal_context, list):
                personal_context = "; ".join(str(item).strip() for item in personal_context if str(item).strip())
            personal_context = str(personal_context).strip()
            if personal_context:
                profile["personal_context"] = personal_context
        existing_profile = db_operations.load_user_profile(self.redis_config, self.user_id)
        replace_fields = profile_update.get("replace_fields") or []
        if isinstance(replace_fields, str):
            replace_fields = [replace_fields]
        replace_fields = set(replace_fields)
        for field in self.LIST_FIELDS:
            values = [] if field in replace_fields else list(existing_profile.get(field) or [])
            update_values = profile_update.get(field) or []
            if isinstance(update_values, str):
                update_values = [update_values]
            for value in update_values:
                value = str(value).strip()
                if field == "medications" and value in self.SUPPLEMENTS_NOT_MEDICATIONS:
                    continue
                if value and value not in values:
                    values.append(value)
            if values:
                profile[field] = values
        return profile

    def missing_required_fields(self):
        profile = db_operations.load_user_profile(self.redis_config, self.user_id)
        return [label for key, label in self.REQUIRED_FIELDS.items() if profile.get(key) in (None, "", [])]

    def context_lines(self, include_required=True, include_forgotten=True):
        profile = {
            key: value
            for key, value in db_operations.load_user_profile(self.redis_config, self.user_id).items()
            if value not in (None, "", [])
        }
        facts = db_operations.load_memory_facts(self.redis_config, self.user_id)
        lines = []
        forgotten_fields = self.forgotten_fields()
        if include_forgotten and forgotten_fields:
            lines.append(
                "FORGOTTEN_PROFILE_FIELDS: The current record intentionally excludes "
                + ", ".join(sorted(forgotten_fields))
                + "; this means the user explicitly asked to remove these fields, not that the user never provided them. Do not restore, quote, or ask to re-provide them unless the user explicitly asks to store a replacement."
            )
        if profile:
            labels = {
                "personal_context": "personal context",
                "age": "年龄",
                "sex": "性别",
                "height_cm": "身高cm",
                "weight_kg": "体重kg",
                "goal": "目标",
                "dietary_preferences": "饮食限制/偏好",
                "training_preferences": "训练偏好",
                "physiological_factors": "身体因素",
                "health_conditions": "健康情况",
                "medications": "用药",
            }
            formatted = []
            for key, value in profile.items():
                if isinstance(value, list):
                    value = "、".join(str(item) for item in value)
                formatted.append(f"{labels.get(key, key)}={value}")
            lines.append("USER_PROFILE_CONFIRMED: 用户明确说过的档案，只能按这些事实个性化回答；不要编造未出现信息。 " + "；".join(formatted))
        else:
            lines.append(
                "USER_PROFILE_CONFIRMED: none. No user name, preference, goal, condition, or other profile fact is currently confirmed."
            )
        missing_fields = self.missing_required_fields()
        if include_required and missing_fields:
            lines.append(
                "PROFILE_REQUIRED: Missing "
                + "、".join(missing_fields)
                + " from the durable confirmed profile. For a personalized health, diet, training, or supplement plan, "
                "ask only for the missing fields that materially change the result and do not give numeric calories, "
                "macros, doses, schedules, or personalized targets until they are available. An explicit self-applied "
                "current-turn statement can be used as a provisional, correctable fact without storing it; otherwise "
                "do not invent a value or present a generic number as the user's plan. Do not mention profile storage "
                "or ask again for a field already supplied explicitly in the current turn."
            )
        if facts:
            lines.append("Durable user facts: " + "; ".join(f"{key}={value}" for key, value in facts.items()))
        return lines
