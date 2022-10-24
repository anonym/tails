from logging import getLogger

from tps_frontend import SPINNER_VIEW_UI_FILE
from tps_frontend.view import View

logger = getLogger(__name__)

class SpinnerView(View):
    _ui_file = SPINNER_VIEW_UI_FILE
