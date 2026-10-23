const path = document.querySelector('.path-disclosure');
if (matchMedia('(max-width: 760px)').matches && path) path.open = false;
const search = document.querySelector('#guide-search');
search?.addEventListener('input', () => {
  const query = search.value.trim().toLowerCase();
  let count = 0;
  document.querySelectorAll('[data-guide]').forEach(item => {
    item.hidden = !item.dataset.guide.includes(query);
    if (!item.hidden) count++;
  });
  document.querySelector('.search-status').textContent = query ? `${count} guides found` : '';
});
if (navigator.clipboard) document.querySelectorAll('.guide-body pre').forEach(pre => {
  const wrapper = document.createElement('div');
  wrapper.className = 'code-block';
  const button = document.createElement('button');
  button.className = 'copy-code';
  button.type = 'button';
  button.textContent = 'Copy';
  button.setAttribute('aria-label', 'Copy code example');
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(pre.textContent);
      button.textContent = 'Copied';
      setTimeout(() => { button.textContent = 'Copy'; }, 1600);
    } catch { button.textContent = 'Select code to copy'; }
  });
  pre.before(wrapper);
  wrapper.append(button, pre);
});
