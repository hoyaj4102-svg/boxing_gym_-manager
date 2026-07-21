/**
 * Sweat Manager - Supabase Auth & Data Service
 * Multi-tenant gym SaaS (gym_id isolation via RLS)
 */
(function (global) {
  const STATE = {
    client: null,
    configured: false,
    user: null,
    profile: null,
    gym: null,
    ready: false
  };

  function getConfig() {
    return global.SWEAT_MANAGER_SUPABASE || {};
  }

  function initClient() {
    const config = getConfig();
    STATE.configured = Boolean(config.url && config.anonKey && global.supabase);

    if (!STATE.configured) {
      STATE.client = null;
      return null;
    }

    STATE.client = global.supabase.createClient(config.url, config.anonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true
      }
    });

    return STATE.client;
  }

  function client() {
    return STATE.client;
  }

  function isConfigured() {
    return STATE.configured;
  }

  function isReady() {
    return Boolean(STATE.client && STATE.user && STATE.profile && STATE.gym && STATE.ready);
  }

  function getUser() {
    return STATE.user;
  }

  function getProfile() {
    return STATE.profile;
  }

  function getGym() {
    return STATE.gym;
  }

  function getGymId() {
    return STATE.profile?.gym_id || STATE.gym?.id || null;
  }

  function rowToMember(row) {
    const attendanceRows = Array.isArray(row.attendance) ? row.attendance : [];
    const attendance = attendanceRows
      .slice()
      .sort((a, b) => new Date(b.created_at) - new Date(a.created_at))
      .map(a => ({
        id: a.id,
        date: a.created_at,
        visitDate: a.attendance_date,
        ptDeducted: Number(a.pt_used) > 0,
        ptUsed: Number(a.pt_used) || 0
      }));

    return {
      id: row.id,
      name: row.name || '',
      phone: row.phone || '',
      startDate: row.start_date,
      expireDate: row.expire_date,
      ptTotal: Number(row.pt_total) || 0,
      ptRemaining: Number(row.pt_remaining) || 0,
      memo: row.memo || '',
      lastVisit: row.last_visit || null,
      totalVisits: Number(row.total_visits) || attendance.length,
      createdAt: row.created_at || new Date().toISOString(),
      updatedAt: row.updated_at || null,
      attendance
    };
  }

  function memberToInsert(member, gymId) {
    return {
      gym_id: gymId,
      name: member.name,
      phone: member.phone || '',
      start_date: member.startDate,
      expire_date: member.expireDate,
      pt_total: member.ptTotal || 0,
      pt_remaining: member.ptRemaining || 0,
      memo: member.memo || '',
      last_visit: member.lastVisit || null,
      total_visits: member.totalVisits || 0
    };
  }

  function memberToUpdate(member) {
    return {
      name: member.name,
      phone: member.phone || '',
      start_date: member.startDate,
      expire_date: member.expireDate,
      pt_total: member.ptTotal || 0,
      pt_remaining: member.ptRemaining || 0,
      memo: member.memo || '',
      last_visit: member.lastVisit || null,
      total_visits: member.totalVisits || 0
    };
  }

  async function loadSessionContext(user) {
    STATE.user = user || null;
    STATE.profile = null;
    STATE.gym = null;
    STATE.ready = false;

    if (!STATE.client || !user) return null;

    const { data: profile, error: profileError } = await STATE.client
      .from('profiles')
      .select('id, gym_id, name, created_at')
      .eq('id', user.id)
      .maybeSingle();

    if (profileError) throw profileError;
    if (!profile) {
      throw new Error('프로필이 없습니다. 회원가입 시 체육관 정보가 생성되어야 합니다.');
    }

    let { data: gym, error: gymError } = await STATE.client
      .from('gyms')
      .select('id, name, owner_name, phone, created_at, plan_code, member_limit, subscription_status, trial_ends_at, current_period_end, billing_provider')
      .eq('id', profile.gym_id)
      .maybeSingle();

    if (gymError) {
      const fallback = await STATE.client
        .from('gyms')
        .select('id, name, owner_name, phone, created_at')
        .eq('id', profile.gym_id)
        .maybeSingle();
      gym = fallback.data;
      gymError = fallback.error;
    }

    if (gymError) throw gymError;
    if (!gym) throw new Error('체육관 정보를 찾을 수 없습니다.');

    STATE.profile = profile;
    STATE.gym = gym;
    STATE.ready = true;
    return { user, profile, gym };
  }

  async function getSession() {
    if (!STATE.client) return null;
    const { data, error } = await STATE.client.auth.getSession();
    if (error) throw error;
    return data.session || null;
  }

  async function signUp({ email, password, gymName, ownerName, phone }) {
    if (!STATE.client) throw new Error('Supabase가 설정되지 않았습니다.');

    const { data, error } = await STATE.client.auth.signUp({
      email,
      password,
      options: {
        data: {
          gym_name: gymName,
          owner_name: ownerName || '',
          phone: phone || ''
        }
      }
    });

    if (error) throw error;
    return data;
  }

  async function signIn(email, password) {
    if (!STATE.client) throw new Error('Supabase가 설정되지 않았습니다.');
    const { data, error } = await STATE.client.auth.signInWithPassword({ email, password });
    if (error) throw error;
    return data;
  }

  async function signOut() {
    if (!STATE.client) return;
    const { error } = await STATE.client.auth.signOut();
    if (error) throw error;
    STATE.user = null;
    STATE.profile = null;
    STATE.gym = null;
    STATE.ready = false;
  }

  async function resetPassword(email) {
    if (!STATE.client) throw new Error('Supabase가 설정되지 않았습니다.');
    const redirectTo = `${global.location.origin}${global.location.pathname}`;
    const { data, error } = await STATE.client.auth.resetPasswordForEmail(email, { redirectTo });
    if (error) throw error;
    return data;
  }

  async function updatePassword(newPassword) {
    if (!STATE.client) throw new Error('Supabase가 설정되지 않았습니다.');
    const { data, error } = await STATE.client.auth.updateUser({ password: newPassword });
    if (error) throw error;
    return data;
  }

  function onAuthStateChange(callback) {
    if (!STATE.client) return { data: { subscription: { unsubscribe() {} } } };
    return STATE.client.auth.onAuthStateChange(callback);
  }

  async function fetchMembers() {
    if (!isReady()) throw new Error('로그인이 필요합니다.');

    const { data, error } = await STATE.client
      .from('members')
      .select('*, attendance(*)')
      .eq('gym_id', getGymId())
      .order('expire_date', { ascending: true });

    if (error) throw error;
    return (data || []).map(rowToMember);
  }

  async function createMember(member) {
    if (!isReady()) throw new Error('로그인이 필요합니다.');

    if (global.SweatManagerBilling) {
      try {
        const summary = await global.SweatManagerBilling.fetchBillingSummary({
          isReady: () => isReady(),
          client
        });
        if (!summary.canAddMember) {
          const err = new Error('MEMBER_LIMIT_REACHED');
          err.code = 'MEMBER_LIMIT_REACHED';
          err.limit = summary.memberLimit;
          throw err;
        }
      } catch (error) {
        if (error?.code === 'MEMBER_LIMIT_REACHED' || error?.message === 'MEMBER_LIMIT_REACHED') {
          throw error;
        }
        // If billing RPC is not installed yet, fall through to DB trigger / insert.
      }
    }

    const payload = memberToInsert(member, getGymId());
    const { data, error } = await STATE.client
      .from('members')
      .insert(payload)
      .select('*, attendance(*)')
      .single();

    if (error) {
      if (String(error.message || '').includes('MEMBER_LIMIT_REACHED')) {
        const err = new Error('MEMBER_LIMIT_REACHED');
        err.code = 'MEMBER_LIMIT_REACHED';
        throw err;
      }
      throw error;
    }
    return rowToMember(data);
  }

  async function updateMember(member) {
    if (!isReady()) throw new Error('로그인이 필요합니다.');

    const { data, error } = await STATE.client
      .from('members')
      .update(memberToUpdate(member))
      .eq('id', member.id)
      .eq('gym_id', getGymId())
      .select('*, attendance(*)')
      .single();

    if (error) throw error;
    return rowToMember(data);
  }

  async function deleteMember(memberId) {
    if (!isReady()) throw new Error('로그인이 필요합니다.');

    const { error } = await STATE.client
      .from('members')
      .delete()
      .eq('id', memberId)
      .eq('gym_id', getGymId());

    if (error) throw error;
  }

  function todayLocalDate() {
    const d = new Date();
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  }

  async function recordAttendance(memberId, attendanceDate = todayLocalDate()) {
    if (!isReady()) throw new Error('로그인이 필요합니다.');

    const { data, error } = await STATE.client.rpc('record_attendance', {
      p_member_id: memberId,
      p_attendance_date: attendanceDate
    });

    if (error) throw error;
    return data;
  }

  async function replaceAllMembers(memberList) {
    if (!isReady()) throw new Error('로그인이 필요합니다.');

    const gymId = getGymId();

    const { error: deleteError } = await STATE.client
      .from('members')
      .delete()
      .eq('gym_id', gymId);

    if (deleteError) throw deleteError;

    if (!memberList.length) return [];

    const inserts = memberList.map(m => memberToInsert(m, gymId));
    const { data: created, error: insertError } = await STATE.client
      .from('members')
      .insert(inserts)
      .select('*');

    if (insertError) throw insertError;

    const attendancePayload = [];
    (created || []).forEach((row, index) => {
      const source = memberList[index];
      const records = Array.isArray(source?.attendance) ? source.attendance : [];
      records.forEach(item => {
        attendancePayload.push({
          member_id: row.id,
          gym_id: gymId,
          attendance_date: item.visitDate || (item.date ? String(item.date).slice(0, 10) : null),
          pt_used: item.ptDeducted === false ? 0 : (Number(item.ptUsed) > 0 ? Number(item.ptUsed) : 1),
          created_at: item.date || new Date().toISOString()
        });
      });
    });

    if (attendancePayload.length) {
      const valid = attendancePayload.filter(a => a.attendance_date);
      if (valid.length) {
        const { error: attendanceError } = await STATE.client
          .from('attendance')
          .insert(valid);
        if (attendanceError) throw attendanceError;
      }
    }

    return fetchMembers();
  }

  async function migrateLocalMembers(localMembers) {
    if (!isReady()) throw new Error('로그인이 필요합니다.');
    if (!localMembers.length) return fetchMembers();

    const gymId = getGymId();
    const createdMembers = [];

    for (const member of localMembers) {
      const { data, error } = await STATE.client
        .from('members')
        .insert(memberToInsert({
          ...member,
          totalVisits: Array.isArray(member.attendance) ? member.attendance.length : (member.totalVisits || 0)
        }, gymId))
        .select('*')
        .single();

      if (error) throw error;

      const records = Array.isArray(member.attendance) ? member.attendance : [];
      if (records.length) {
        const payload = records
          .map(item => ({
            member_id: data.id,
            gym_id: gymId,
            attendance_date: item.visitDate || (item.date ? String(item.date).slice(0, 10) : null),
            pt_used: item.ptDeducted === false ? 0 : (Number(item.ptUsed) > 0 ? Number(item.ptUsed) : 1),
            created_at: item.date || new Date().toISOString()
          }))
          .filter(a => a.attendance_date);

        if (payload.length) {
          const { error: attendanceError } = await STATE.client
            .from('attendance')
            .insert(payload);
          if (attendanceError) throw attendanceError;
        }
      }

      createdMembers.push(data);
    }

    return fetchMembers();
  }

  global.SweatManagerDB = {
    STATE,
    initClient,
    client,
    isConfigured,
    isReady,
    getUser,
    getProfile,
    getGym,
    getGymId,
    loadSessionContext,
    getSession,
    signUp,
    signIn,
    signOut,
    resetPassword,
    updatePassword,
    onAuthStateChange,
    fetchMembers,
    createMember,
    updateMember,
    deleteMember,
    recordAttendance,
    replaceAllMembers,
    migrateLocalMembers,
    rowToMember
  };
})(window);
