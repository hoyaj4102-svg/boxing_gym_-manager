// Public business-identity placeholders for re;member.
// Every value is intentionally unfilled. Do not replace these with real
// registration numbers, addresses, phone numbers, or email addresses in git.
(function (global) {
  const PLACEHOLDERS = Object.freeze({
    status: 'placeholder',
    legalReview: 'pending',
    legalName: '[상호 미기재]',
    businessRegistrationNumber: '[사업자등록번호 미기재]',
    representativeName: '[대표자 미기재]',
    address: '[주소 미기재]',
    phone: '[전화 미기재]',
    mailOrderReportNumber: '[통신판매업 신고번호 미기재]',
    email: '[이메일 미기재]'
  });

  const FIELDS = Object.freeze([
    ['legalName', '상호'],
    ['representativeName', '대표자'],
    ['businessRegistrationNumber', '사업자등록번호'],
    ['mailOrderReportNumber', '통신판매업 신고번호'],
    ['address', '주소'],
    ['phone', '전화'],
    ['email', '이메일']
  ]);

  function escapeText(value) {
    return String(value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function renderInto(root) {
    if (!root) return;
    const rows = FIELDS.map(([key, label]) => (
      `<div><dt>${escapeText(label)}</dt><dd>${escapeText(PLACEHOLDERS[key])}</dd></div>`
    )).join('');
    const base = root.dataset && Object.prototype.hasOwnProperty.call(root.dataset, 'legalBase')
      ? root.dataset.legalBase
      : 'legal/';
    root.innerHTML = `
      <p class="business-footer-draft">사업자 정보, 이용약관, 개인정보처리방침, 환불정책은 법률 검토 전 초안입니다. 아래 식별정보는 자리표시자이며 실제 값이 아닙니다.</p>
      <dl class="business-identity">${rows}</dl>
      <nav class="business-footer-nav" aria-label="약관">
        <a href="${base}terms.html">이용약관 (초안)</a>
        <a href="${base}privacy.html">개인정보처리방침 (초안)</a>
        <a href="${base}refund.html">환불정책 (초안)</a>
      </nav>
    `;
  }

  function renderAll(doc) {
    const documentRef = doc || global.document;
    if (!documentRef) return;
    documentRef.querySelectorAll('[data-business-footer], [data-business-identity]').forEach((root) => {
      renderInto(root);
    });
  }

  global.SweatManagerBusiness = {
    PLACEHOLDERS,
    FIELDS,
    renderInto,
    renderAll
  };
})(typeof window !== 'undefined' ? window : globalThis);
